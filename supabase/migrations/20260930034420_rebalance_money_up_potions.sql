-- Rebalance the Money Up Potion line. The live sell path reads the active
-- boost's effect_value, so updating the catalog also updates future boosts
-- without changing the optimized roll or auto-sell implementations.

begin;

update public.game_consumables
set effect_value = case id
  when 'money-up-potion' then 1.1
  when 'money-up-potion-2' then 1.25
end
where id in ('money-up-potion', 'money-up-potion-2');

-- Active boosts normally expire after 60 seconds, but rebalance them too so
-- the change is consistent immediately when this migration is applied.
update public.player_boosts
set effect_value = case tier
  when 1 then 1.1
  when 2 then 1.25
  else effect_value
end
where family = 'gemValue' and tier in (1, 2);

insert into public.game_recipes(id, recipe) values
  ('money-up-potion', '{
    "id":"money-up-potion",
    "name":"Money Up Potion",
    "category":"potion",
    "requirements":[
      {"type":"consumable","consumableId":"lucky-potion-1","amount":5},
      {"type":"consumable","consumableId":"fortune-potion-1","amount":5}
    ],
    "moneyCost":25000,
    "reward":{"type":"consumable","id":"money-up-potion","name":"Money Up Potion","family":"gemValue","tier":1,"amount":1,"effectValue":1.1}
  }'::jsonb),
  ('money-up-potion-2', '{
    "id":"money-up-potion-2",
    "name":"Money Up Potion II",
    "category":"potion",
    "requirements":[
      {"type":"consumable","consumableId":"lucky-potion-2","amount":5},
      {"type":"consumable","consumableId":"fortune-potion-2","amount":5},
      {"type":"consumable","consumableId":"money-up-potion","amount":3}
    ],
    "moneyCost":100000,
    "reward":{"type":"consumable","id":"money-up-potion-2","name":"Money Up Potion II","family":"gemValue","tier":2,"amount":1,"effectValue":1.25}
  }'::jsonb)
on conflict (id) do update set recipe = excluded.recipe;

-- Consumable-only recipes never create a crafting_progress row because their
-- requirements are checked directly against player_consumables. Treat absent
-- deposited progress as an empty object so those recipes can be crafted while
-- recipes with gem/material requirements still fail their normal checks.
create or replace function public.craft_consumable_recipe(p_recipe_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_player_id uuid := auth.uid();
  v_recipe jsonb;
  v_reward_id text;
  v_money_cost numeric;
  v_progress jsonb;
  v_requirement jsonb;
  v_index integer;
  v_key text;
  v_target numeric;
  v_owned integer;
  v_total_rolls bigint;
  v_quantity integer;
begin
  if v_player_id is null then raise exception 'not_authenticated'; end if;

  select recipe into v_recipe
  from public.game_recipes
  where id = p_recipe_id;
  if v_recipe is null or v_recipe #>> '{reward,type}' <> 'consumable' then
    raise exception 'recipe_not_found';
  end if;

  v_reward_id := v_recipe #>> '{reward,id}';
  v_money_cost := coalesce((v_recipe ->> 'moneyCost')::numeric, 0);

  select total_rolls into v_total_rolls
  from public.players
  where id = v_player_id
  for update;
  if not found then raise exception 'player_not_found'; end if;

  select progress into v_progress
  from public.crafting_progress
  where player_id = v_player_id and recipe_id = p_recipe_id
  for update;
  v_progress := coalesce(v_progress, '{}'::jsonb);

  for v_requirement, v_index in
    select value, (ordinality - 1)::integer
    from jsonb_array_elements(coalesce(v_recipe -> 'requirements', '[]'::jsonb)) with ordinality
  loop
    if v_requirement ->> 'type' = 'lifetime-rolls' then
      if v_total_rolls < coalesce((v_requirement ->> 'rolls')::bigint, 0) then
        raise exception 'requirements_not_met';
      end if;
    elsif v_requirement ->> 'type' = 'consumable' then
      select quantity into v_owned
      from public.player_consumables
      where player_id = v_player_id
        and consumable_id = v_requirement ->> 'consumableId'
      for update;
      if not found or v_owned < coalesce((v_requirement ->> 'amount')::integer, 1) then
        raise exception 'consumables_not_owned';
      end if;
    else
      v_key := coalesce(
        v_requirement ->> 'id',
        case when v_requirement ->> 'type' = 'gem-count'
          then v_requirement ->> 'gem'
          else (v_requirement ->> 'type') || '-' || v_index::text end
      );
      v_target := case v_requirement ->> 'type'
        when 'gem-count' then coalesce((v_requirement ->> 'amount')::numeric, 1)
        when 'gem-total-weight' then (v_requirement ->> 'totalWeight')::numeric
        when 'specimen-total-weight' then (v_requirement ->> 'totalWeight')::numeric
        when 'specimen-value-total' then (v_requirement ->> 'totalValue')::numeric
        else coalesce((v_requirement ->> 'amount')::numeric, 1)
      end;
      if coalesce((v_progress ->> v_key)::numeric, 0) < v_target then
        raise exception 'requirements_not_met';
      end if;
    end if;
  end loop;

  perform 1 from public.players
  where id = v_player_id and money >= v_money_cost
  for update;
  if not found then raise exception 'insufficient_funds'; end if;

  update public.players
  set money = money - v_money_cost
  where id = v_player_id;

  for v_requirement in
    select value from jsonb_array_elements(coalesce(v_recipe -> 'requirements', '[]'::jsonb))
  loop
    if v_requirement ->> 'type' = 'consumable' then
      update public.player_consumables
      set quantity = quantity - coalesce((v_requirement ->> 'amount')::integer, 1),
          updated_at = now()
      where player_id = v_player_id
        and consumable_id = v_requirement ->> 'consumableId';
    end if;
  end loop;

  insert into public.player_consumables(player_id, consumable_id, quantity, updated_at)
  values (v_player_id, v_reward_id, 1, now())
  on conflict (player_id, consumable_id) do update
  set quantity = public.player_consumables.quantity + 1,
      updated_at = now()
  returning quantity into v_quantity;

  delete from public.crafting_progress
  where player_id = v_player_id and recipe_id = p_recipe_id;

  return jsonb_build_object(
    'success', true,
    'recipeId', p_recipe_id,
    'consumableId', v_reward_id,
    'quantity', v_quantity
  );
end;
$function$;

revoke all on function public.craft_consumable_recipe(text) from public, anon;
grant execute on function public.craft_consumable_recipe(text) to authenticated, service_role;

commit;
