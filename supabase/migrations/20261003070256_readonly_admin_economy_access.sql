-- Economy reports are read-only, so both write-capable administrators and
-- admin_viewers may execute the existing reporting functions. Preserve each
-- function body and widen only its admins-table authorization predicate.
do $migration$
declare
  function_row record;
  updated_definition text;
begin
  for function_row in
    select p.oid, p.proname, pg_get_functiondef(p.oid) as definition
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.proname in (
        'admin_get_economy_breakdown',
        'admin_get_lottery_analytics',
        'get_admin_analytics',
        'admin_get_bank_overview'
      )
  loop
    updated_definition := regexp_replace(
      function_row.definition,
      'exists\s*\(\s*select\s+1\s+from\s+public\.admins(?:\s+[a-z_][a-z0-9_]*)?\s+where\s+(?:[a-z_][a-z0-9_]*\.)?user_id\s*=\s*(auth\.uid\(\)|v_uid)\s*\)',
      E'(\\& or exists (select 1 from public.admin_viewers where user_id = \\1))',
      'gi'
    );

    if updated_definition = function_row.definition then
      raise exception 'Could not add admin_viewers authorization to %', function_row.proname;
    end if;

    execute updated_definition;
  end loop;
end;
$migration$;
