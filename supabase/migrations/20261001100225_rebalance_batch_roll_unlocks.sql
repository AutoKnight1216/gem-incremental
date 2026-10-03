-- Rebalance the built-in batch-roll unlocks and add the ×5 specialist gate.
-- Prepared against project igrddscmrdrrwtvyspbf. Manual deployment only.
begin;

create or replace function public.roll_batch_unlock_status(
  p_player_id uuid,
  p_batch_size integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_total_rolls bigint;
  v_has_celestial boolean;
  v_specialist_pickaxes integer;
  v_roll_bulk integer;
  v_maximum_batch_size integer;
begin
  if p_player_id is null
     or p_batch_size is null
     or p_batch_size < 1 then
    return jsonb_build_object('status', 'invalid_batch_size');
  end if;

  select coalesce(total_rolls, 0)
  into v_total_rolls
  from public.players
  where id = p_player_id;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  select
    exists (
      select 1
      from public.equipment_ownership_history
      where player_id = p_player_id
        and equipment_id = 'celestial-pickaxe'
    )
    or exists (
      select 1
      from public.player_equipment
      where player_id = p_player_id
        and equipment_id = 'celestial-pickaxe'
    )
  into v_has_celestial;

  select count(distinct equipment_id)
  into v_specialist_pickaxes
  from (
    select equipment_id
    from public.equipment_ownership_history
    where player_id = p_player_id
    union
    select equipment_id
    from public.player_equipment
    where player_id = p_player_id
  ) owned
  where equipment_id in (
    'fortune-pickaxe',
    'all-in-pickaxe',
    'empyrean-pickaxe',
    'eternity-pickaxe',
    'tectonic-pickaxe',
    'the-accelerator',
    'the-resonator',
    'the-excavator',
    'bedrock-pickaxe',
    'supersizer-pickaxe'
  );

  select coalesce(sum(greatest(0, roll_bulk_bonus)), 0)
  into v_roll_bulk
  from public.player_equipment
  where player_id = p_player_id
    and equipped;

  -- ×5 is now part of normal progression. Roll Bulk adds slots above it.
  v_maximum_batch_size := least(100, 5 + v_roll_bulk);

  if p_batch_size <= 2 then
    return jsonb_build_object(
      'status', 'unlocked',
      'maximumBatchSize', v_maximum_batch_size,
      'rollBulkBonus', v_roll_bulk
    );
  end if;

  if p_batch_size = 3 and v_total_rolls >= 50000 then
    return jsonb_build_object(
      'status', 'unlocked',
      'maximumBatchSize', v_maximum_batch_size,
      'rollBulkBonus', v_roll_bulk
    );
  end if;

  if p_batch_size = 4
     and v_total_rolls >= 200000
     and v_has_celestial then
    return jsonb_build_object(
      'status', 'unlocked',
      'maximumBatchSize', v_maximum_batch_size,
      'rollBulkBonus', v_roll_bulk
    );
  end if;

  if p_batch_size >= 5
     and p_batch_size <= v_maximum_batch_size
     and v_total_rolls >= 500000
     and v_specialist_pickaxes >= 3 then
    return jsonb_build_object(
      'status', 'unlocked',
      'maximumBatchSize', v_maximum_batch_size,
      'rollBulkBonus', v_roll_bulk,
      'specialistPickaxes', v_specialist_pickaxes
    );
  end if;

  if p_batch_size > v_maximum_batch_size then
    return jsonb_build_object(
      'status', 'invalid_batch_size',
      'maximumBatchSize', v_maximum_batch_size,
      'rollBulkBonus', v_roll_bulk
    );
  end if;

  return jsonb_build_object(
    'status', 'batch_locked',
    'totalRolls', v_total_rolls,
    'requiredTotalRolls',
      case
        when p_batch_size = 3 then 50000
        when p_batch_size = 4 then 200000
        when p_batch_size >= 5 then 500000
        else 0
      end,
    'requiresCelestialPickaxe', p_batch_size = 4,
    'hasCelestialPickaxe', v_has_celestial,
    'requiredSpecialistPickaxes', case when p_batch_size >= 5 then 3 else 0 end,
    'specialistPickaxes', v_specialist_pickaxes,
    'maximumBatchSize', v_maximum_batch_size,
    'rollBulkBonus', v_roll_bulk
  );
end;
$$;

revoke all on function public.roll_batch_unlock_status(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.roll_batch_unlock_status(uuid, integer)
  to service_role;

commit;
