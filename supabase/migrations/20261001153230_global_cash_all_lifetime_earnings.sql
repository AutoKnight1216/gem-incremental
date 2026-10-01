-- Global cash is the sum of every player's lifetime earnings. Economy account
-- exclusions still apply to the separate current-wallet and bank series.
begin;

create or replace function public.get_global_cash()
returns double precision
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(p.lifetime_earnings), 0)::double precision
  from public.players p
$$;

revoke execute on function public.get_global_cash() from public;
grant execute on function public.get_global_cash() to anon, authenticated;

create or replace function public.get_global_cash_feed()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'total', coalesce((select sum(p.lifetime_earnings) from public.players p), 0),
    'cash', coalesce((select sum(p.money) from public.players p), 0),
    'online', coalesce((
      select count(*)
      from public.player_presence pp
      where pp.last_seen_at > now() - interval '2 minutes'
    ), 0),
    'events', coalesce((
      select jsonb_agg(row_to_json(e))
      from (
        select
          gce.id,
          gce.player_name as name,
          gce.gem_name as gem,
          gce.amount,
          gce.created_at as at
        from public.global_cash_events gce
        order by gce.id desc
        limit 10
      ) e
    ), '[]'::jsonb)
  )
$$;

revoke execute on function public.get_global_cash_feed() from public;
grant execute on function public.get_global_cash_feed() to anon, authenticated;

create or replace function public.snapshot_global_cash()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.global_cash_history (lifetime, money, bank)
  select
    (select coalesce(sum(all_players.lifetime_earnings), 0)
     from public.players all_players),
    coalesce(sum(p.money), 0),
    (select coalesce(sum(b.balance), 0)
     from public.bank_accounts b
     where not exists (
       select 1
       from public.system_account_exclusions e
       where e.player_id = b.player_id
         and e.exclude_from_economy
     ))
  from public.players p
  where not exists (
    select 1
    from public.system_account_exclusions e
    where e.player_id = p.id
      and e.exclude_from_economy
  );

  delete from public.global_cash_history
  where id <= (select max(id) - 2000 from public.global_cash_history);
end;
$$;

revoke execute on function public.snapshot_global_cash() from public, anon, authenticated;
grant execute on function public.snapshot_global_cash() to service_role;

create or replace function public.get_cash_market_tick()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  tick public.cash_market_tick%rowtype;
begin
  select * into tick
  from public.cash_market_tick
  where id = 1;

  if coalesce(tick.at, '-infinity') < clock_timestamp() - interval '1 second'
     and pg_try_advisory_xact_lock(hashtext('public.cash_market_tick')) then
    insert into public.cash_market_tick (id, lifetime, money, bank, at)
    select
      1,
      (select coalesce(sum(all_players.lifetime_earnings), 0)
       from public.players all_players),
      coalesce(sum(p.money), 0),
      (select coalesce(sum(b.balance), 0)
       from public.bank_accounts b
       where not exists (
         select 1
         from public.system_account_exclusions e
         where e.player_id = b.player_id
           and e.exclude_from_economy
       )),
      clock_timestamp()
    from public.players p
    where not exists (
      select 1
      from public.system_account_exclusions e
      where e.player_id = p.id
        and e.exclude_from_economy
    )
    on conflict (id) do update
      set lifetime = excluded.lifetime,
          money = excluded.money,
          bank = excluded.bank,
          at = excluded.at
    returning * into tick;
  end if;

  return jsonb_build_object(
    'at', tick.at,
    'lifetime', coalesce(tick.lifetime, 0),
    'money', coalesce(tick.money, 0),
    'bank', coalesce(tick.bank, 0)
  );
end;
$$;

revoke execute on function public.get_cash_market_tick() from public;
grant execute on function public.get_cash_market_tick() to anon, authenticated;

-- Correct the current chart point immediately and force the next live request
-- to recalculate rather than serving a previously filtered value.
select public.snapshot_global_cash();
update public.cash_market_tick
set at = '-infinity'::timestamptz
where id = 1;

commit;
