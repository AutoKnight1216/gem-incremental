-- Phase 6: reduce Edge Function -> PostgREST request amplification while
-- keeping RNG, formula evaluation and response shaping in TypeScript.
-- Prepared from the live igrddscmrdrrwtvyspbf definitions on 2026-10-02.
-- Intentionally not deployed by Codex.
begin;

-- Add invocation-stable event/catalogue rows to the existing authoritative
-- context in-process. Failures are represented in the payload so normal rolls
-- retain the staged-deployment fallback that the Edge Function had when these
-- were separate requests.
create or replace function public.roll_prepare_context_v2(
  p_player_id uuid,
  p_now timestamptz,
  p_gem_catalog_version bigint default null,
  p_mutation_catalog_version bigint default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_context jsonb;
  v_deepcore jsonb := null;
  v_deep_sea jsonb := null;
  v_warnings jsonb := '[]'::jsonb;
begin
  v_context := public.roll_prepare_context(
    p_player_id, p_now, p_gem_catalog_version, p_mutation_catalog_version
  );

  begin
    v_deepcore := public.deepcore_get_roll_context(p_player_id);
  exception when others then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'context', 'deepcore', 'message', sqlerrm
    ));
  end;

  begin
    v_deep_sea := public.deep_sea_get_roll_context(p_player_id);
  exception when others then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'context', 'deep_sea', 'message', sqlerrm
    ));
  end;

  return v_context || jsonb_build_object(
    'player', coalesce(v_context->'player', '{}'::jsonb) || jsonb_build_object(
      'money', (select money from public.players where id = p_player_id)
    ),
    'deepcoreContext', v_deepcore,
    'deepSeaContext', v_deep_sea,
    'pets', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.id)
      from (
        select id, name, chance_denominator, affected_by_luck, enabled, stats
        from public.game_pets
        where enabled = true
      ) p
    ), '[]'::jsonb),
    'equipmentBonusRows', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.id)
      from (
        select id, equipment_id, roll_bulk_bonus, pet_luck_bonus
        from public.player_equipment
        where player_id = p_player_id and equipped = true
      ) e
    ), '[]'::jsonb),
    'contextWarnings', v_warnings
  );
end;
$$;

revoke all on function public.roll_prepare_context_v2(uuid, timestamptz, bigint, bigint)
  from public, anon, authenticated;
grant execute on function public.roll_prepare_context_v2(uuid, timestamptz, bigint, bigint)
  to service_role;

-- A Deep Sea batch must re-check its phase and mutable feed state between
-- subrolls. Fold that refresh into the already-serialized subroll transition;
-- normal batches keep reusing the stable first snapshot.
create or replace function public.roll_begin_batch_subroll_v2(
  p_player_id uuid,
  p_lease_id uuid,
  p_genuine_roll bigint,
  p_now timestamptz,
  p_refresh_deep_sea boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_deep_sea jsonb := null;
  v_warning text := null;
begin
  v_result := public.roll_begin_batch_subroll(
    p_player_id, p_lease_id, p_genuine_roll, p_now
  );

  if coalesce(p_refresh_deep_sea, false) then
    begin
      v_deep_sea := public.deep_sea_get_roll_context(p_player_id);
    exception when others then
      v_warning := sqlerrm;
    end;
  end if;

  return v_result || jsonb_build_object(
    'deepSeaContext', v_deep_sea,
    'deepSeaContextError', v_warning
  );
end;
$$;

revoke all on function public.roll_begin_batch_subroll_v2(uuid, uuid, bigint, timestamptz, boolean)
  from public, anon, authenticated;
grant execute on function public.roll_begin_batch_subroll_v2(uuid, uuid, bigint, timestamptz, boolean)
  to service_role;

-- Bundle precedence and Auto Craft must be known before JS decides whether a
-- duplicate may occupy inventory. Resolve both in one database transaction and
-- return the same two receipts that the separate calls returned previously.
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
begin
  select * into v_player
  from public.players
  where id = p_player_id
  for update;

  if not found or p_lease_id is null
     or v_player.roll_lease_id is distinct from p_lease_id then
    raise exception 'invalid_roll_lease';
  end if;

  if p_external_deposit is not null then
    v_bundle := jsonb_build_object(
      'status', p_external_deposit,
      'keepInInventory', false
    );
  elsif coalesce(p_filter_keep, false) then
    v_bundle := jsonb_build_object(
      'status', 'kept',
      'keepInInventory', true,
      'reason', 'filter'
    );
  else
    v_bundle := public.bundle_route_roll(p_player_id, p_lease_id, p_specimen);
  end if;

  if coalesce(v_bundle->>'status', 'none') <> 'deposited'
     and not coalesce((v_bundle->>'keepInInventory')::boolean, false) then
    if p_active_auto_craft = 'paradox-pickaxe' then
      begin
        v_auto_craft := public.paradox_autocraft_deposit(p_player_id, p_specimen);
      exception when others then
        v_auto_craft_error := sqlerrm;
      end;
    elsif p_active_auto_craft is not null then
      begin
        v_auto_craft := public.roll_autocraft_deposit(p_player_id, p_specimen);
      exception when others then
        v_auto_craft_error := sqlerrm;
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

-- Keep the inventory column mapping in one internal helper. The JSON is fully
-- produced by server-side TypeScript after RNG; callers cannot execute this
-- helper directly through anon/authenticated Data API roles.
create or replace function public.roll_insert_inventory_specimen(
  p_player_id uuid,
  p_specimen jsonb
)
returns public.inventory_gems
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_row public.inventory_gems%rowtype;
begin
  insert into public.inventory_gems (
    player_id, gem_name, rarity, base_weight, value_per_gram,
    rolled_weight_multiplier, rolled_weight, final_weight,
    mutation_id, mutation_multiplier, mutation_ids, mutation_multipliers,
    natural_mutation_ids, effective_rarity, genuine_roll,
    mutation_chance_multiplier, value, locked, roll_number, luck_at_roll,
    source_event_occurrence_id, source_event_key, event_properties,
    value_multiplier_at_roll
  ) values (
    p_player_id,
    p_specimen->>'gem_name',
    (p_specimen->>'rarity')::integer,
    (p_specimen->>'base_weight')::double precision,
    (p_specimen->>'value_per_gram')::double precision,
    (p_specimen->>'rolled_weight_multiplier')::double precision,
    (p_specimen->>'rolled_weight')::double precision,
    (p_specimen->>'final_weight')::double precision,
    nullif(p_specimen->>'mutation_id', ''),
    coalesce((p_specimen->>'mutation_multiplier')::numeric, 1),
    array(select jsonb_array_elements_text(coalesce(p_specimen->'mutation_ids', '[]'::jsonb))),
    coalesce(p_specimen->'mutation_multipliers', '{}'::jsonb),
    array(select jsonb_array_elements_text(coalesce(p_specimen->'natural_mutation_ids', '[]'::jsonb))),
    (p_specimen->>'effective_rarity')::numeric,
    coalesce((p_specimen->>'genuine_roll')::boolean, false),
    coalesce((p_specimen->>'mutation_chance_multiplier')::numeric, 1),
    (p_specimen->>'value')::double precision,
    coalesce((p_specimen->>'locked')::boolean, false),
    (p_specimen->>'roll_number')::bigint,
    (p_specimen->>'luck_at_roll')::numeric,
    nullif(p_specimen->>'source_event_occurrence_id', '')::uuid,
    nullif(p_specimen->>'source_event_key', ''),
    coalesce(p_specimen->'event_properties', '{}'::jsonb),
    coalesce((p_specimen->>'value_multiplier_at_roll')::numeric, 1)
  ) returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.roll_insert_inventory_specimen(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.roll_insert_inventory_specimen(uuid, jsonb)
  to service_role;

-- Atomically persist the JS-generated specimens, equipment state and critical
-- bookkeeping. Auto-sell remains best-effort: if it fails, its subtransaction
-- rolls back and the newly inserted specimen is retained exactly as before.
create or replace function public.roll_commit_result(
  p_player_id uuid,
  p_lease_id uuid,
  p_genuine_roll bigint,
  p_primary_specimen jsonb,
  p_save_primary boolean,
  p_relic_drop boolean,
  p_duplicate jsonb,
  p_auto_sell boolean,
  p_state jsonb,
  p_loot text,
  p_bonus jsonb,
  p_capacity integer,
  p_player_patch jsonb,
  p_bookkeeping jsonb,
  p_include_background boolean default false,
  p_release_on_success boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_player public.players%rowtype;
  v_primary public.inventory_gems%rowtype;
  v_duplicate public.inventory_gems%rowtype;
  v_equipment jsonb;
  v_money double precision := null;
  v_sold boolean := false;
  v_sale_error text := null;
  v_duplicate_error text := null;
  v_lease_released boolean := false;
begin
  select * into v_player
  from public.players
  where id = p_player_id
  for update;

  if not found or v_player.roll_lease_id is distinct from p_lease_id then
    raise exception 'invalid_roll_lease';
  end if;
  if v_player.equipment_state_roll >= p_genuine_roll then
    return jsonb_build_object('duplicateCommit', true);
  end if;
  if p_genuine_roll <> v_player.equipment_genuine_rolls + 1 then
    raise exception 'invalid_genuine_roll';
  end if;

  if coalesce(p_save_primary, false) then
    if coalesce(p_relic_drop, false) then
      perform public.grant_player_relic(
        p_player_id, p_primary_specimen->>'gem_name', 1
      );
    else
      v_primary := public.roll_insert_inventory_specimen(p_player_id, p_primary_specimen);
    end if;
  end if;

  if p_duplicate is not null then
    begin
      v_duplicate := public.roll_insert_inventory_specimen(p_player_id, p_duplicate);
    exception when others then
      v_duplicate_error := sqlerrm;
    end;
  end if;

  v_equipment := public.commit_equipment_roll(
    p_player_id, p_lease_id, p_genuine_roll, p_state, p_loot, p_bonus,
    p_capacity, p_player_patch, p_bookkeeping, p_include_background
  );

  if coalesce(p_auto_sell, false) and v_primary.id is not null then
    begin
      v_money := public.sell_inventory_gem(p_player_id, v_primary.id, 'auto');
      v_sold := true;
    exception when others then
      v_sale_error := sqlerrm;
    end;
  end if;

  if coalesce(p_release_on_success, false) then
    update public.players
    set roll_lease_id = null,
        roll_lease_expires_at = null
    where id = p_player_id and roll_lease_id = p_lease_id;
    v_lease_released := found;
  end if;

  return jsonb_build_object(
    'primary', case when v_primary.id is not null then to_jsonb(v_primary) else null end,
    'duplicate', case when v_duplicate.id is not null then to_jsonb(v_duplicate) else null end,
    'duplicateError', v_duplicate_error,
    'equipment', v_equipment,
    'leaseReleased', v_lease_released,
    'sale', jsonb_build_object(
      'sold', v_sold,
      'money', v_money,
      'error', v_sale_error
    )
  );
end;
$$;

revoke all on function public.roll_commit_result(
  uuid, uuid, bigint, jsonb, boolean, boolean, jsonb, boolean,
  jsonb, text, jsonb, integer, jsonb, jsonb, boolean, boolean
) from public, anon, authenticated;
grant execute on function public.roll_commit_result(
  uuid, uuid, bigint, jsonb, boolean, boolean, jsonb, boolean,
  jsonb, text, jsonb, integer, jsonb, jsonb, boolean, boolean
) to service_role;

commit;
