-- The legacy players.lifetime_earnings counter intentionally includes many
-- cash sources. Keep those semantics for achievements and other progression,
-- while giving the leaderboard an exact gem-sales-only source of truth.

create table economy_private.player_gem_sale_earnings (
  player_id uuid primary key,
  amount numeric not null default 0 check (
    amount >= 0
    and amount not in ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
  ),
  updated_at timestamptz not null default statement_timestamp()
);

alter table economy_private.player_gem_sale_earnings enable row level security;
revoke all on table economy_private.player_gem_sale_earnings
  from public, anon, authenticated, service_role;

-- Recover every gem sale recorded since the authoritative cash ledger began.
insert into economy_private.player_gem_sale_earnings (player_id, amount)
select
  l.player_id,
  sum(l.amount)
from public.economy_cash_ledger l
where l.player_id is not null
  and l.account = 'wallet'
  and l.direction = 'source'
  and l.category = 'gem_sales'
  and l.amount > 0
group by l.player_id
on conflict (player_id) do update
set
  amount = excluded.amount,
  updated_at = statement_timestamp();

create function economy_private.track_gem_sale_earnings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  insert into economy_private.player_gem_sale_earnings (
    player_id,
    amount,
    updated_at
  ) values (
    new.player_id,
    new.amount,
    new.created_at
  )
  on conflict (player_id) do update
  set
    amount = economy_private.player_gem_sale_earnings.amount + excluded.amount,
    updated_at = greatest(
      economy_private.player_gem_sale_earnings.updated_at,
      excluded.updated_at
    );

  return null;
end;
$function$;

revoke all on function economy_private.track_gem_sale_earnings()
  from public, anon, authenticated, service_role;

create trigger economy_track_gem_sale_earnings
after insert on public.economy_cash_ledger
for each row
when (
  new.player_id is not null
  and new.account = 'wallet'
  and new.direction = 'source'
  and new.category = 'gem_sales'
  and new.amount > 0
)
execute function economy_private.track_gem_sale_earnings();

create or replace function public.get_lifetime_earnings_leaderboard(
  p_limit integer default 100
)
returns table(
  rank bigint,
  username text,
  lifetime_earnings numeric
)
language sql
stable
security definer
set search_path = ''
as $function$
  select
    row_number() over(order by e.amount desc, p.id) as rank,
    p.username,
    e.amount as lifetime_earnings
  from economy_private.player_gem_sale_earnings e
  join public.players p on p.id = e.player_id
  where p.username is not null
    and coalesce(p.leaderboard_hidden, false) = false
    and e.amount > 0
  order by e.amount desc, p.id
  limit greatest(1, least(coalesce(p_limit, 100), 100));
$function$;

revoke all on function public.get_lifetime_earnings_leaderboard(integer)
  from public, anon, authenticated;
grant execute on function public.get_lifetime_earnings_leaderboard(integer)
  to service_role;
