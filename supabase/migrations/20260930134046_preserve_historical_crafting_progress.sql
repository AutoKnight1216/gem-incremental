-- Keep cumulative crafting gates cumulative even when an in-flight roll commits
-- equipment state that was loaded before another roll or action advanced them.
begin;

create or replace function public.preserve_equipment_batch_history()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_key text;
  v_old_value jsonb;
  v_new_value jsonb;
  v_history jsonb := coalesce(new.equipment_state->'batchHistory', '{}'::jsonb);
begin
  for v_key, v_old_value in
    select key, value
    from jsonb_each(coalesce(old.equipment_state->'batchHistory', '{}'::jsonb))
  loop
    if jsonb_typeof(v_old_value) <> 'number' then
      continue;
    end if;

    v_new_value := v_history->v_key;
    if v_new_value is null
      or jsonb_typeof(v_new_value) <> 'number'
      or (v_new_value #>> '{}')::numeric < (v_old_value #>> '{}')::numeric
    then
      v_history := jsonb_set(v_history, array[v_key], v_old_value, true);
    end if;
  end loop;

  new.equipment_state := jsonb_set(
    coalesce(new.equipment_state, '{}'::jsonb),
    '{batchHistory}',
    v_history,
    true
  );
  return new;
end;
$$;

revoke all on function public.preserve_equipment_batch_history() from public, anon, authenticated;

drop trigger if exists preserve_equipment_batch_history on public.players;
create trigger preserve_equipment_batch_history
before update of equipment_state on public.players
for each row
execute function public.preserve_equipment_batch_history();

-- Crafting requirements labelled as lifetime rolls use the canonical lifetime
-- counter, not the equipment-era genuine-roll counter.
create or replace function public.equipment_batch_progress(p_uid uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(p.equipment_state->'batchHistory', '{}'::jsonb) || jsonb_build_object(
    'genuineRolls', coalesce(p.total_rolls, 0),
    'lifetimeEarnings', coalesce(p.lifetime_earnings, 0),
    'endgamePickaxes', (
      select count(*)
      from public.equipment_ownership_history h
      where h.player_id = p.id
        and h.equipment_id in (
          'empyrean-pickaxe', 'eternity-pickaxe', 'tectonic-pickaxe',
          'the-accelerator', 'the-resonator', 'the-excavator',
          'fortune-pickaxe', 'all-in-pickaxe', 'bedrock-pickaxe'
        )
    ),
    'supersizerSpecialists', (
      select count(distinct h.equipment_id)
      from public.equipment_ownership_history h
      where h.player_id = p.id
        and h.equipment_id in (
          'fortune-pickaxe', 'empyrean-pickaxe', 'eternity-pickaxe',
          'tectonic-pickaxe', 'the-accelerator', 'the-resonator',
          'the-excavator', 'bedrock-pickaxe'
        )
    ),
    'supersizerHeavy10', greatest(
      coalesce((p.equipment_state->'batchHistory'->>'supersizerHeavy10')::numeric, 0),
      (select count(*) from public.inventory_gems i
       where i.player_id = p.id and i.base_weight > 0 and i.final_weight / i.base_weight >= 10)
    ),
    'supersizerRareHeavy5', greatest(
      coalesce((p.equipment_state->'batchHistory'->>'supersizerRareHeavy5')::numeric, 0),
      (select count(*) from public.inventory_gems i
       where i.player_id = p.id and i.rarity >= 10000000
         and i.base_weight > 0 and i.final_weight / i.base_weight >= 5)
    )
  )
  from public.players p
  where p.id = p_uid
$$;

revoke all on function public.equipment_batch_progress(uuid) from public, anon, authenticated;
grant execute on function public.equipment_batch_progress(uuid) to service_role;

commit;
