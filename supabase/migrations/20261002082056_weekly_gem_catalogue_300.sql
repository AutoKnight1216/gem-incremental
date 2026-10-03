-- Weekly gem catalogue expansion: 281 currently-visible entries -> 300.
-- Duolite is already present but future-dated, so it is deliberately not
-- assigned a catalogueOrder in this batch.

begin;

insert into public.private_feature_gems (
  name, rarity, base_weight, value_per_gram, description, metadata,
  hide_rarity_until_discovered, affected_by_luck, special_gem, sort_order,
  availability_mode, availability_timezone, enabled
)
values
  ('e', 2718281, 2718, 1839.85,
   'Euler number very pro yes ok (by @SandwichedCat)',
   '{"catalogueOrder":282,"creator":"@SandwichedCat","creatorLocked":true,"puzzleClue":"Raise e to the product of π and the missing value, then add one."}'::jsonb,
   false, true, false, 98, 'always', 'Asia/Singapore', true),
  ('Jade', 125, 320, 0.75,
   'A durable ornamental stone prized for its smooth polish and rich green colour. For thousands of years, jade has been shaped into tools, jewellery and ceremonial objects.',
   '{"catalogueOrder":283}'::jsonb,
   false, true, false, 224, 'always', 'Asia/Singapore', true),
  ('Verity', 77000000, 7, 11000000,
   'A perfectly clear crystal that reveals every flaw in whatever is viewed through it. The longer it is held, the harder it becomes to look away.',
   '{"catalogueOrder":284}'::jsonb,
   true, true, false, 47, 'always', 'Asia/Singapore', true),
  ('Calmarite', 50000000, 12, 2500000,
   'A cool blue crystal that quiets every vibration around it. Even deep underground, the air beside it feels unnaturally still.',
   '{"catalogueOrder":285}'::jsonb,
   true, true, false, 51, 'always', 'Asia/Singapore', true),
  ('Incandescity', 2000000000, 0.25, 500000000,
   'A gem made from light so intense that it condensed into a solid. Its glow never dims, yet it gives off no heat. (by @Flame)',
   '{"catalogueOrder":286,"creator":"@Flame","creatorLocked":true}'::jsonb,
   true, true, false, 33, 'always', 'Asia/Singapore', true),
  ('Långbanshyttanite', 65000000, 0.4, 125000000,
   'An exceptionally rare lead manganese silicate from the Långban mining district in Sweden. Its name is nearly as formidable as finding a specimen. (by @SandwichedCat)',
   '{"catalogueOrder":287,"creator":"@SandwichedCat","creatorLocked":true}'::jsonb,
   true, true, false, 49, 'always', 'Asia/Singapore', true),
  ('Uvarovite', 18000, 8, 12500,
   'A vivid emerald-green garnet coloured by chromium. It commonly forms as a glittering crust of tiny crystals rather than as large individual gems.',
   '{"catalogueOrder":288}'::jsonb,
   false, true, false, 132, 'always', 'Asia/Singapore', true),
  ('Rainbow Lattice Sunstone', 850000, 3.5, 600000,
   'A rare feldspar whose internal lattice scatters light into geometric flashes of every colour. Each angle reveals a different pattern suspended inside the stone.',
   '{"catalogueOrder":289}'::jsonb,
   false, true, false, 112, 'always', 'Asia/Singapore', true),
  ('Chkalovite', 3200000, 1.2, 3500000,
   'A rare sodium beryllium silicate first identified in alkaline rocks. Its pale crystals conceal an unusually complex chemical structure.',
   '{"catalogueOrder":290}'::jsonb,
   false, true, false, 95, 'always', 'Asia/Singapore', true),
  ('Nabesite', 8250000, 0.8, 12500000,
   'A rare hydrated beryllium silicate found in alkaline mineral environments. Clear specimens resemble frozen droplets caught between surrounding crystals.',
   '{"catalogueOrder":291}'::jsonb,
   false, true, false, 79, 'always', 'Asia/Singapore', true),
  ('Neptunite', 12500000, 2.5, 8000000,
   'A dark red-black mineral whose sharply formed crystals flash deep crimson at their edges. It was named for Neptune, counterpart to aegirine''s Aegir.',
   '{"catalogueOrder":292}'::jsonb,
   true, true, false, 72, 'always', 'Asia/Singapore', true),
  ('Kuannersuite-(Ce)', 35000000, 0.15, 150000000,
   'An exceptionally rare cerium-bearing mineral named for Kuannersuit in Greenland. Its scarcity reflects the unusual chemistry of the rocks in which it formed.',
   '{"catalogueOrder":293}'::jsonb,
   true, true, false, 57, 'always', 'Asia/Singapore', true),
  ('Chromaflux', 225000000, 1, 225000000,
   'Colour flows through this crystal in slow currents, never settling on the same spectrum twice. Nearby gems briefly borrow its hues before returning to normal.',
   '{"catalogueOrder":294}'::jsonb,
   true, true, false, 25, 'always', 'Asia/Singapore', true),
  ('Parallax', 350000000, 2, 175000000,
   'Its core appears displaced from every viewing angle. Two observers can hold the same crystal and disagree completely about where it is.',
   '{"catalogueOrder":295}'::jsonb,
   true, true, false, 18, 'always', 'Asia/Singapore', true),
  ('Liminalite', 500000000, 0.5, 1000000000,
   'A mineral found only at boundaries: doorways, shorelines and the instant between waking and sleep. Once moved, the place it came from is impossible to find again.',
   '{"catalogueOrder":296}'::jsonb,
   true, true, false, 10, 'always', 'Asia/Singapore', true),
  ('Chronofracture', 275000000, 0.001, 750000000000,
   'A broken sliver of time held in crystalline form. Reflections across its surface show the moment before it was found and the moment after it is lost.',
   '{"catalogueOrder":297}'::jsonb,
   true, true, false, 5, 'always', 'Asia/Singapore', true),
  ('Ore+', 965000000, 10000, 250,
   'Found only from asteroids astray from their paths, Ore+ is a valuable fuel source. However, as u pick it up, u feel something moving inside.',
   '{"catalogueOrder":298}'::jsonb,
   true, true, false, 4, 'always', 'Asia/Singapore', true),
  ('i', 1, 1, 0,
   'This ore should not exist. (by @SandwichedCat)',
   '{"catalogueOrder":299,"creator":"@SandwichedCat","creatorLocked":true,"rarityClass":"anomalous","displayRarity":-1,"normalRng":false,"sourceExclusive":true,"sourceLabel":"Gem Index puzzle","onePerAccount":true,"automaticConsumptionProtected":true}'::jsonb,
   true, false, true, 10000, 'always', 'Asia/Singapore', true),
  ('300', 300000000, 300, 1000000,
   'Three hundred gems. Every stone before this one left a mark; this one exists to count them.',
   '{"catalogueOrder":300,"milestone":true}'::jsonb,
   true, true, false, 20, 'always', 'Asia/Singapore', true)
on conflict (name) do update set
  rarity = excluded.rarity,
  base_weight = excluded.base_weight,
  value_per_gram = excluded.value_per_gram,
  description = excluded.description,
  metadata = public.private_feature_gems.metadata || excluded.metadata,
  hide_rarity_until_discovered = excluded.hide_rarity_until_discovered,
  affected_by_luck = excluded.affected_by_luck,
  special_gem = excluded.special_gem,
  sort_order = excluded.sort_order,
  availability_mode = excluded.availability_mode,
  availability_timezone = excluded.availability_timezone,
  enabled = excluded.enabled,
  updated_at = now();

-- π and e form the discoverable half of the imaginary-number trail.
update public.private_feature_gems
set metadata = metadata || jsonb_build_object(
  'puzzleClue', 'The circle closes at π, but the answer lies outside the reals.'
), updated_at = now()
where name = 'π';

-- One reusable policy marker protects any future special specimen from
-- automatic sale, crafting or contribution without adding name checks.
create or replace function public.gem_automatic_consumption_protected(p_gem_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select (g.metadata->>'automaticConsumptionProtected')::boolean
    from public.private_feature_gems g
    where g.name = p_gem_name and g.enabled = true
  ), false)
$$;

revoke all on function public.gem_automatic_consumption_protected(text)
  from public, anon, authenticated;
grant execute on function public.gem_automatic_consumption_protected(text)
  to service_role;

create schema if not exists private;

create table if not exists private.gem_puzzle_claims (
  player_id uuid not null references public.players(id) on delete cascade,
  puzzle_id text not null,
  claimed_at timestamptz not null default now(),
  specimen_id bigint references public.inventory_gems(id) on delete set null,
  primary key (player_id, puzzle_id)
);

create or replace function public.claim_anomalous_i(p_answer text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_player_id uuid := auth.uid();
  v_catalog public.private_feature_gems%rowtype;
  v_specimen public.inventory_gems%rowtype;
  v_value double precision;
begin
  if v_player_id is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if lower(trim(coalesce(p_answer, ''))) <> 'i' then
    raise exception 'incorrect_answer' using errcode = '22023';
  end if;

  perform 1 from public.players where id = v_player_id for update;
  if not found then raise exception 'player_not_found'; end if;

  if not exists (
    select 1 from public.player_gem_mutation_combinations
    where player_id = v_player_id and gem_name = 'π'
  ) or not exists (
    select 1 from public.player_gem_mutation_combinations
    where player_id = v_player_id and gem_name = 'e'
  ) then
    raise exception 'prerequisites_not_met' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from private.gem_puzzle_claims
    where player_id = v_player_id and puzzle_id = 'imaginary-unit'
  ) then
    raise exception 'already_claimed' using errcode = '23505';
  end if;

  select * into v_catalog
  from public.private_feature_gems
  where name = 'i' and enabled = true
  for share;
  if not found then raise exception 'puzzle_unavailable'; end if;

  if (select count(*) from public.inventory_gems where player_id = v_player_id)
     >= (select inventory_capacity + coalesce((select inventory_bonus from public.player_research_effects where player_id = v_player_id), 0)
         from public.players where id = v_player_id) then
    raise exception 'inventory_full' using errcode = 'P0001';
  end if;

  v_value := v_catalog.base_weight * v_catalog.value_per_gram;
  insert into public.inventory_gems (
    player_id, gem_name, rarity, base_weight, value_per_gram,
    rolled_weight_multiplier, rolled_weight, final_weight, value,
    mutation_multiplier, mutation_ids, mutation_multipliers,
    mutation_chance_multiplier, locked, museum_locked, luck_at_roll,
    natural_mutation_ids, effective_rarity, genuine_roll
  ) values (
    v_player_id, v_catalog.name, v_catalog.rarity::integer,
    v_catalog.base_weight::double precision,
    v_catalog.value_per_gram::double precision,
    1, v_catalog.base_weight::double precision,
    v_catalog.base_weight::double precision, v_value,
    1, '{}'::text[], '{}'::jsonb, 1, true, false, 1,
    '{}'::text[], 1, false
  ) returning * into v_specimen;

  insert into private.gem_puzzle_claims(player_id, puzzle_id, specimen_id)
  values (v_player_id, 'imaginary-unit', v_specimen.id);

  perform public.record_gem_mutation_combination(
    v_player_id, 'i', 'none', '{}'::text[], '{}'::jsonb, v_value::numeric
  );

  return jsonb_build_object(
    'claimed', true,
    'specimenId', v_specimen.id,
    'gemName', 'i',
    'locked', true,
    'displayRarity', -1
  );
end;
$$;

revoke all on function public.claim_anomalous_i(text) from public, anon;
grant execute on function public.claim_anomalous_i(text) to authenticated;

-- Preserve manual sale semantics while rejecting every automatic sale of a
-- protected specimen, even if a caller bypasses the ordinary filter decision.
create or replace function public.sell_inventory_gem(
  p_player_id uuid,
  p_specimen_id bigint,
  p_source text default 'manual'
)
returns double precision
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_value double precision;
  v_locked boolean;
  v_new_money double precision;
  v_gem_name text;
  v_name text;
  v_gem_value_mult double precision;
begin
  select value, locked, gem_name
    into v_value, v_locked, v_gem_name
    from public.inventory_gems
    where id = p_specimen_id and player_id = p_player_id
    for update;

  if not found then raise exception 'gem_not_found'; end if;
  if v_locked then raise exception 'gem_locked'; end if;
  if p_source = 'auto' and public.gem_automatic_consumption_protected(v_gem_name) then
    raise exception 'automatic_consumption_protected';
  end if;

  v_value := v_value * public.equipment_gem_sell_multiplier(p_player_id);
  if p_source = 'auto' then
    select effect_value into v_gem_value_mult
    from public.player_boosts
    where player_id = p_player_id and family = 'gemValue' and expires_at > now()
    limit 1;
    if v_gem_value_mult is not null and v_gem_value_mult > 1 then
      v_value := v_value * v_gem_value_mult;
    end if;
  end if;

  update public.players
  set money = money + v_value,
      lifetime_earnings = lifetime_earnings + v_value
  where id = p_player_id
  returning money into v_new_money;

  delete from public.inventory_gems
  where id = p_specimen_id and player_id = p_player_id;

  begin
    select username into v_name from public.players where id = p_player_id;
    insert into public.global_cash_events(player_name, gem_name, amount)
    values (v_name, v_gem_name, v_value);
  exception when others then null;
  end;
  return v_new_money;
end;
$$;

revoke all on function public.sell_inventory_gem(uuid, bigint, text)
  from public, anon, authenticated;
grant execute on function public.sell_inventory_gem(uuid, bigint, text)
  to service_role;

-- Central routing gate: bundles, Paradox Auto Craft and ordinary Auto Craft all
-- receive a keep receipt for policy-protected gems.
create or replace function public.roll_route_result(
  p_player_id uuid,
  p_lease_id uuid,
  p_specimen jsonb,
  p_filter_keep boolean,
  p_active_auto_craft text default null,
  p_external_deposit text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_player public.players%rowtype;
  v_bundle jsonb;
  v_auto_craft jsonb := jsonb_build_object(
    'deposited', false, 'preserved', false,
    'recipeId', null, 'requirementIndex', null
  );
  v_auto_craft_error text := null;
  v_protected boolean := coalesce(
    public.gem_automatic_consumption_protected(p_specimen->>'gem_name'), false
  );
begin
  select * into v_player
  from public.players
  where id = p_player_id
  for update;

  if not found or p_lease_id is null
     or v_player.roll_lease_id is distinct from p_lease_id then
    raise exception 'invalid_roll_lease';
  end if;

  if v_protected then
    v_bundle := jsonb_build_object(
      'status', 'protected', 'keepInInventory', true,
      'reason', 'automatic-consumption-protection'
    );
  elsif p_external_deposit is not null then
    v_bundle := jsonb_build_object('status', p_external_deposit, 'keepInInventory', false);
  elsif coalesce(p_filter_keep, false) then
    v_bundle := jsonb_build_object('status', 'kept', 'keepInInventory', true, 'reason', 'filter');
  else
    v_bundle := public.bundle_route_roll(p_player_id, p_lease_id, p_specimen);
  end if;

  if not v_protected
     and coalesce(v_bundle->>'status', 'none') <> 'deposited'
     and not coalesce((v_bundle->>'keepInInventory')::boolean, false) then
    if p_active_auto_craft = 'paradox-pickaxe' then
      begin
        v_auto_craft := public.paradox_autocraft_deposit(p_player_id, p_specimen);
      exception when others then v_auto_craft_error := sqlerrm;
      end;
    elsif p_active_auto_craft is not null then
      begin
        v_auto_craft := public.roll_autocraft_deposit(p_player_id, p_specimen);
      exception when others then v_auto_craft_error := sqlerrm;
      end;
    end if;
  end if;

  return jsonb_build_object(
    'bundle', v_bundle,
    'autoCraft', v_auto_craft,
    'autoCraftError', v_auto_craft_error
  );
end;
$$;

revoke all on function public.roll_route_result(uuid, uuid, jsonb, boolean, text, text)
  from public, anon, authenticated;
grant execute on function public.roll_route_result(uuid, uuid, jsonb, boolean, text, text)
  to service_role;

commit;
