-- =========================================================
-- CASH MARKET — live tick
--
-- The Cash Market page ticks like a stock quote, polling roughly every
-- 0.7-1s. Summing every player on each of those calls would scale with the
-- number of viewers, so the economy totals are cached in a one-row table and
-- recomputed at most once per second, by whichever caller first finds the
-- cache stale. Concurrent callers that lose the advisory lock simply return
-- the cached row, so there is never more than one recompute in flight.
--
-- Totals mirror snapshot_global_cash() (20260904102117): accounts flagged in
-- system_account_exclusions are left out, so live ticks line up with the
-- 10-minute history samples the chart is drawn from.
-- =========================================================

create table if not exists public.cash_market_tick (
  id smallint primary key default 1 check (id = 1),
  lifetime double precision not null default 0,
  money double precision not null default 0,
  bank double precision not null default 0,
  at timestamptz not null default '-infinity'
);

alter table public.cash_market_tick enable row level security;
revoke all on public.cash_market_tick from public, anon, authenticated;

insert into public.cash_market_tick (id)
values (1)
on conflict (id) do nothing;

-- Returns { at, lifetime, money, bank } — at most one second old.
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
      coalesce(sum(p.lifetime_earnings), 0),
      coalesce(sum(p.money), 0),
      (select coalesce(sum(b.balance), 0)
       from public.bank_accounts b
       where not exists (
         select 1 from public.system_account_exclusions e
         where e.player_id = b.player_id and e.exclude_from_economy
       )),
      clock_timestamp()
    from public.players p
    where not exists (
      select 1 from public.system_account_exclusions e
      where e.player_id = p.id and e.exclude_from_economy
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
