-- Keep recent cash events row-addressable for investigations, while moving the
-- overwhelming historical gem-sale stream into compressed, checksummed chunks.
-- Exact source rows remain recoverable; reporting reads a compact daily rollup.
begin;

create table economy_private.cash_ledger_archive_chunks (
  archive_id bigint generated always as identity primary key,
  format_version smallint not null default 1 check (format_version = 1),
  first_ledger_id bigint not null unique,
  last_ledger_id bigint not null unique,
  first_created_at timestamptz not null,
  last_created_at timestamptz not null,
  event_count integer not null check (event_count > 0),
  payload jsonb not null check (jsonb_typeof(payload) = 'array'),
  payload_md5 text not null,
  archived_at timestamptz not null default clock_timestamp(),
  check (first_ledger_id <= last_ledger_id),
  check (first_created_at <= last_created_at),
  check (jsonb_array_length(payload) = event_count),
  check (md5(payload::text) = payload_md5)
);
comment on table economy_private.cash_ledger_archive_chunks is
  'Exact immutable economy_cash_ledger rows packed as ordered JSON arrays. Format v1 row order: id, created_at, transaction_id, player_id, account, amount, direction, category, subcategory, reference, metadata.';
alter table economy_private.cash_ledger_archive_chunks enable row level security;
revoke all on economy_private.cash_ledger_archive_chunks from public, anon, authenticated, service_role;

create index cash_ledger_archive_chunks_time
  on economy_private.cash_ledger_archive_chunks(first_created_at, last_created_at);

create table economy_private.cash_ledger_daily_rollups (
  ledger_date date not null,
  player_id uuid not null,
  account text not null check (account in ('wallet','bank','clearing')),
  direction text not null check (direction in ('source','sink','transfer')),
  category text not null,
  subcategory text not null,
  amount numeric not null,
  credited numeric not null check (credited >= 0),
  debited numeric not null check (debited >= 0),
  entries bigint not null check (entries > 0),
  first_ledger_id bigint not null,
  last_ledger_id bigint not null,
  first_created_at timestamptz not null,
  last_created_at timestamptz not null,
  primary key (ledger_date, player_id, account, direction, category, subcategory),
  check (first_ledger_id <= last_ledger_id),
  check (first_created_at <= last_created_at)
);
comment on table economy_private.cash_ledger_daily_rollups is
  'Per-player/day accounting totals for exact ledger rows held in cash_ledger_archive_chunks.';
alter table economy_private.cash_ledger_daily_rollups enable row level security;
revoke all on economy_private.cash_ledger_daily_rollups from public, anon, authenticated, service_role;

-- A bounded recovery interface avoids accidentally expanding the complete
-- archive. Database owners can use it to inspect or restore exact events.
create function economy_private.read_archived_cash_ledger(
  p_from_ledger_id bigint,
  p_to_ledger_id bigint,
  p_limit integer default 1000
)
returns table (
  id bigint,
  created_at timestamptz,
  transaction_id bigint,
  player_id uuid,
  account text,
  amount numeric,
  direction text,
  category text,
  subcategory text,
  reference text,
  metadata jsonb
)
language sql stable security invoker set search_path = '' as $$
  select
    (event.value->>0)::bigint,
    (event.value->>1)::timestamptz,
    (event.value->>2)::bigint,
    (event.value->>3)::uuid,
    event.value->>4,
    (event.value->>5)::numeric,
    event.value->>6,
    event.value->>7,
    event.value->>8,
    event.value->>9,
    event.value->10
  from economy_private.cash_ledger_archive_chunks chunk
  cross join lateral jsonb_array_elements(chunk.payload) with ordinality as event(value, position)
  where chunk.last_ledger_id >= p_from_ledger_id
    and chunk.first_ledger_id <= p_to_ledger_id
    and (event.value->>0)::bigint between p_from_ledger_id and p_to_ledger_id
  order by (event.value->>0)::bigint
  limit greatest(1, least(coalesce(p_limit, 1000), 10000));
$$;
revoke all on function economy_private.read_archived_cash_ledger(bigint,bigint,integer)
  from public, anon, authenticated, service_role;

create function economy_private.compact_cash_ledger_batch(
  p_cutoff timestamptz default null,
  p_max_rows integer default 10000
)
returns jsonb
language plpgsql security definer set search_path = '' set lock_timeout = '2s' as $$
declare
  v_safe_cutoff timestamptz := date_trunc('day', statement_timestamp()) - interval '8 days';
  v_cutoff timestamptz := coalesce(p_cutoff, v_safe_cutoff);
  v_limit integer := greatest(1, least(coalesce(p_max_rows, 10000), 25000));
  v_rows integer;
  v_deleted integer;
  v_first_id bigint;
  v_last_id bigint;
  v_first_at timestamptz;
  v_last_at timestamptz;
  v_payload jsonb;
  v_archive_id bigint;
begin
  if v_cutoff > v_safe_cutoff then
    raise exception 'cash_ledger_cutoff_must_retain_eight_days';
  end if;

  if not pg_catalog.pg_try_advisory_xact_lock(
    pg_catalog.hashtextextended('economy_private.compact_cash_ledger_batch', 0)
  ) then
    return jsonb_build_object('status','busy','archivedRows',0);
  end if;

  create temporary table if not exists pg_temp.economy_cash_compaction_ids (
    id bigint primary key
  ) on commit drop;
  truncate table pg_temp.economy_cash_compaction_ids;

  insert into pg_temp.economy_cash_compaction_ids(id)
  select l.id
  from public.economy_cash_ledger l
  where l.created_at < v_cutoff
    and l.category = 'gem_sales'
    and l.player_id is not null
    and not exists (
      select 1 from economy_private.cash_correction_annotations a where a.ledger_id = l.id
    )
  -- Lead with created_at so the existing ledger time index can stop at the
  -- cutoff instead of rescanning the retained hot window on every idle run.
  order by l.created_at, l.id
  for update of l skip locked
  limit v_limit;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    return jsonb_build_object('status','caught_up','archivedRows',0,'cutoff',v_cutoff);
  end if;

  select
    min(l.id), max(l.id), min(l.created_at), max(l.created_at),
    jsonb_agg(jsonb_build_array(
      l.id, l.created_at, l.transaction_id, l.player_id, l.account, l.amount,
      l.direction, l.category, l.subcategory, l.reference, l.metadata
    ) order by l.id)
  into v_first_id, v_last_id, v_first_at, v_last_at, v_payload
  from public.economy_cash_ledger l
  join pg_temp.economy_cash_compaction_ids selected on selected.id = l.id;

  insert into economy_private.cash_ledger_archive_chunks(
    first_ledger_id, last_ledger_id, first_created_at, last_created_at,
    event_count, payload, payload_md5
  ) values (
    v_first_id, v_last_id, v_first_at, v_last_at,
    v_rows, v_payload, md5(v_payload::text)
  ) returning archive_id into v_archive_id;

  insert into economy_private.cash_ledger_daily_rollups(
    ledger_date, player_id, account, direction, category, subcategory,
    amount, credited, debited, entries,
    first_ledger_id, last_ledger_id, first_created_at, last_created_at
  )
  select
    (l.created_at at time zone 'UTC')::date,
    l.player_id, l.account, l.direction, l.category, l.subcategory,
    sum(l.amount),
    coalesce(sum(l.amount) filter (where l.amount > 0), 0),
    coalesce(-sum(l.amount) filter (where l.amount < 0), 0),
    count(*), min(l.id), max(l.id), min(l.created_at), max(l.created_at)
  from public.economy_cash_ledger l
  join pg_temp.economy_cash_compaction_ids selected on selected.id = l.id
  group by (l.created_at at time zone 'UTC')::date,
    l.player_id, l.account, l.direction, l.category, l.subcategory
  on conflict (ledger_date, player_id, account, direction, category, subcategory)
  do update set
    amount = economy_private.cash_ledger_daily_rollups.amount + excluded.amount,
    credited = economy_private.cash_ledger_daily_rollups.credited + excluded.credited,
    debited = economy_private.cash_ledger_daily_rollups.debited + excluded.debited,
    entries = economy_private.cash_ledger_daily_rollups.entries + excluded.entries,
    first_ledger_id = least(economy_private.cash_ledger_daily_rollups.first_ledger_id, excluded.first_ledger_id),
    last_ledger_id = greatest(economy_private.cash_ledger_daily_rollups.last_ledger_id, excluded.last_ledger_id),
    first_created_at = least(economy_private.cash_ledger_daily_rollups.first_created_at, excluded.first_created_at),
    last_created_at = greatest(economy_private.cash_ledger_daily_rollups.last_created_at, excluded.last_created_at);

  delete from public.economy_cash_ledger l
  using pg_temp.economy_cash_compaction_ids selected
  where l.id = selected.id;
  get diagnostics v_deleted = row_count;

  if v_deleted <> v_rows then
    raise exception 'cash_ledger_archive_delete_mismatch: archived %, deleted %', v_rows, v_deleted;
  end if;

  return jsonb_build_object(
    'status','archived', 'archiveId',v_archive_id, 'archivedRows',v_rows,
    'firstLedgerId',v_first_id, 'lastLedgerId',v_last_id,
    'firstCreatedAt',v_first_at, 'lastCreatedAt',v_last_at, 'cutoff',v_cutoff
  );
end;
$$;
revoke all on function economy_private.compact_cash_ledger_batch(timestamptz,integer)
  from public, anon, authenticated, service_role;

-- Preserve current report semantics. Only All-time needs archived rollups; the
-- shorter periods are wholly covered by the retained eight-day raw window.
create or replace function public.admin_get_economy_breakdown(p_period text default '24H') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_started timestamptz; v_from timestamptz; v_now timestamptz:=statement_timestamp(); v_result jsonb;
begin
  if auth.uid() is null or not (auth.uid()='38d5e8ce-18af-46d3-aa9e-6e601e75dd78'::uuid
    or exists(select 1 from public.admins where user_id=auth.uid())) then
    raise exception 'not_admin' using errcode='42501';
  end if;
  if p_period is null or p_period not in ('1H','6H','24H','7D','All') then
    raise exception 'invalid_economy_period';
  end if;
  select started_at into v_started from economy_private.tracking where singleton;
  v_from:=greatest(v_started,case p_period when '1H' then v_now-interval '1 hour'
    when '6H' then v_now-interval '6 hours' when '24H' then v_now-interval '24 hours'
    when '7D' then v_now-interval '7 days' else v_started end);

  with classified as materialized (
    select
      case when a.ledger_id is not null or l.category='account_removal' then 'correction'
           when l.category='unattributed' then 'unclassified' else l.direction end as report_direction,
      case when a.ledger_id is not null then a.correction_type
           when l.category='account_removal' then 'account_removal'
           when l.category='unattributed' then 'unclassified' else l.category end as report_category,
      case when a.ledger_id is not null then l.category else l.subcategory end as report_subcategory,
      l.direction as original_direction, l.category as original_category,
      case when a.ledger_id is not null then a.reason
           when l.category='account_removal' then
             'Account deletion or administrative cleanup; preserved for supply reconciliation, not gameplay destruction.'
           else null end as correction_reason,
      l.account, l.amount, 1::bigint as entries,
      case when l.amount>0 then l.amount else 0 end as credited,
      case when l.amount<0 then -l.amount else 0 end as debited
    from public.economy_cash_ledger l
    left join economy_private.cash_correction_annotations a on a.ledger_id=l.id
    where l.created_at>=v_from and l.created_at<=v_now
      and not exists (
        select 1 from public.system_account_exclusions e
        where e.player_id=l.player_id and e.exclude_from_economy
      )
    union all
    select r.direction, r.category, r.subcategory, r.direction, r.category, null::text,
      r.account, r.amount, r.entries, r.credited, r.debited
    from economy_private.cash_ledger_daily_rollups r
    where p_period='All'
      and r.last_created_at>=v_from and r.first_created_at<=v_now
      and not exists (
        select 1 from public.system_account_exclusions e
        where e.player_id=r.player_id and e.exclude_from_economy
      )
  ), grouped as materialized (
    select report_direction direction,report_category category,report_subcategory subcategory,
      original_direction,original_category,correction_reason,account,
      sum(amount) amount,sum(entries) entries,sum(credited) credited,sum(debited) debited
    from classified
    group by report_direction,report_category,report_subcategory,
      original_direction,original_category,correction_reason,account
  ), totals as (
    select coalesce(sum(amount) filter(where direction='source'),0) created,
      coalesce(-sum(amount) filter(where direction='sink'),0) destroyed,
      coalesce(-sum(amount) filter(where direction='transfer' and category='bank_deposit' and account='wallet'),0) deposited,
      coalesce(sum(amount) filter(where direction='transfer' and category='bank_withdrawal' and account='wallet'),0) withdrawn,
      coalesce(sum(amount) filter(where direction='transfer'),0) transfer_net,
      coalesce(sum(amount) filter(where direction='correction'),0) correction_net,
      coalesce(sum(entries) filter(where direction='correction'),0) correction_entries,
      coalesce(sum(amount) filter(where direction='unclassified'),0) unclassified_net,
      coalesce(sum(entries) filter(where direction='unclassified'),0) unclassified_entries,
      coalesce(sum(amount) filter(where account<>'clearing'),0) balance_change,
      coalesce(sum(entries) filter(where account<>'clearing'),0) balance_events
    from grouped
  ), breakdown as (
    select direction,category,subcategory,original_direction,original_category,correction_reason,
      sum(amount) amount,sum(entries) entries,sum(credited) credited,sum(debited) debited
    from grouped where direction<>'unclassified'
    group by direction,category,subcategory,original_direction,original_category,correction_reason
  ), supply as (
    select (select coalesce(sum(p.money::numeric),0) from public.players p where not exists(
      select 1 from public.system_account_exclusions e where e.player_id=p.id and e.exclude_from_economy)) wallets,
      (select coalesce(sum(b.balance::numeric),0) from public.bank_accounts b where not exists(
      select 1 from public.system_account_exclusions e where e.player_id=b.player_id and e.exclude_from_economy)) deposits
  )
  select jsonb_build_object(
    'period',p_period,'trackingSince',v_started,'periodStart',v_from,'generatedAt',v_now,
    'cashCreated',t.created,'cashDestroyed',t.destroyed,'netCreation',t.created-t.destroyed,
    'walletToBank',t.deposited,'bankToWallet',t.withdrawn,'transferNet',t.transfer_net,
    'correctionNet',t.correction_net,'correctionEntries',t.correction_entries,
    'unclassifiedNet',t.unclassified_net,'unclassifiedEntries',t.unclassified_entries,
    'balanceChange',t.balance_change,'balanceEvents',t.balance_events,
    'reconciliationDifference',t.balance_change-
      ((t.created-t.destroyed)+t.transfer_net+t.correction_net+t.unclassified_net),
    'walletCash',s.wallets,'bankDeposits',s.deposits,'totalMoneySupply',s.wallets+s.deposits,
    'breakdown',coalesce((select jsonb_agg(jsonb_build_object(
      'direction',direction,'category',category,'subcategory',subcategory,
      'originalDirection',original_direction,'originalCategory',original_category,
      'correctionReason',correction_reason,'amount',amount,'entries',entries,
      'credited',credited,'debited',debited) order by direction,category,subcategory,original_category)
      from breakdown),'[]'::jsonb)
  ) into v_result from totals t cross join supply s;
  return v_result;
end;
$$;

-- Lottery All-time ratios also need historical gem-sale totals after compaction.
create or replace function public.admin_get_lottery_analytics(p_period text default '24H') returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  v_now timestamptz:=clock_timestamp();
  v_from timestamptz;
  v_result jsonb;
begin
  if auth.uid() is null or not (auth.uid()='38d5e8ce-18af-46d3-aa9e-6e601e75dd78'::uuid
    or exists(select 1 from public.admins where user_id=auth.uid())) then
    raise exception 'not_admin' using errcode='42501';
  end if;
  if p_period is null or p_period not in ('1H','6H','24H','7D','All') then raise exception 'invalid_economy_period'; end if;
  v_from:=case p_period when '1H' then v_now-interval '1 hour' when '6H' then v_now-interval '6 hours'
    when '24H' then v_now-interval '24 hours' when '7D' then v_now-interval '7 days' else '-infinity'::timestamptz end;
  with draws as materialized (
    select * from public.lottery_draws where status='settled' and settled_at between v_from and v_now
  ), allocations as materialized (
    select a.* from public.lottery_allocations a join draws d on d.id=a.draw_id
  ), participant_totals as materialized (
    select player_id,sum(ticket_count) tickets,sum(purchase_total) spending,count(*) draws_entered
    from allocations group by player_id
  ), ledger_parts as materialized (
    select amount,direction,category
    from public.economy_cash_ledger l where l.created_at between v_from and v_now
      and not exists(select 1 from public.system_account_exclusions e where e.player_id=l.player_id and e.exclude_from_economy)
    union all
    select r.amount,r.direction,r.category
    from economy_private.cash_ledger_daily_rollups r
    where p_period='All'
      and not exists(select 1 from public.system_account_exclusions e where e.player_id=r.player_id and e.exclude_from_economy)
  ), ledger_totals as materialized (
    select coalesce(-sum(amount) filter(where direction='sink'),0) all_sinks,
      coalesce(sum(amount) filter(where category='gem_sales' and amount>0),0) gem_sales
    from ledger_parts
  ), totals as (
    select count(*) draws,coalesce(sum(total_tickets),0) tickets,coalesce(sum(gross_revenue),0) gross,
      coalesce(sum(final_prize),0) payouts,coalesce(sum(effective_burn),0) burn,
      coalesce(sum(unique_participants),0) participant_entries from draws
  )
  select jsonb_build_object('period',p_period,'periodStart',v_from,'generatedAt',v_now,
    'draws',t.draws,'totalTickets',t.tickets,'grossSpending',t.gross,'payouts',t.payouts,'netBurn',t.burn,
    'effectiveBurnRate',case when t.gross>0 then t.burn/t.gross else 0 end,
    'participantEntries',t.participant_entries,'uniqueParticipants',(select count(*) from participant_totals),
    'repeatParticipants',(select count(*) from participant_totals where draws_entered>1),
    'medianTicketsPerParticipant',coalesce((select percentile_cont(.5) within group(order by tickets) from participant_totals),0),
    'largestDrawSpender',coalesce((select max(purchase_total) from allocations),0),
    'largestPurchase',coalesce((select max(cost) from public.lottery_purchase_requests r where r.outcome='purchased' and r.created_at between v_from and v_now),0),
    'topPlayerSpendingShare',coalesce((select max(spending)/nullif(sum(spending),0) from participant_totals),0),
    'lotteryShareOfSinks',case when l.all_sinks>0 then t.gross/l.all_sinks else 0 end,
    'burnVsGemSaleRevenue',case when l.gem_sales>0 then t.burn/l.gem_sales else 0 end,
    'finalBands',coalesce((select jsonb_object_agg(final_activity_band,n) from
      (select final_activity_band,count(*) n from draws group by final_activity_band) b),'{}'::jsonb),
    'drawAudit',coalesce((select jsonb_agg(jsonb_build_object('drawId',id,'drawDate',draw_date,
      'openAt',open_at,'cutoffAt',cutoff_at,'drawAt',draw_at,'settledAt',settled_at,'status',status,
      'payoutBasisPoints',payout_basis_points,'totalTickets',total_tickets,'uniqueParticipants',unique_participants,
      'grossRevenue',gross_revenue,'winningInteger',winning_integer,'winnerId',winner_id,
      'winnerTicketCount',winner_ticket_count,'prize',final_prize,'effectiveBurn',effective_burn,
      'finalActivityBand',final_activity_band,'settlementReference',settlement_reference) order by draw_date desc) from draws),'[]'::jsonb)
  ) into v_result from totals t cross join ledger_totals l;
  return v_result;
end;
$$;

-- Ten thousand rows per minute clears the existing backlog gradually and then
-- idles cheaply. Named scheduling makes the migration safe to reapply in a branch.
do $$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    perform cron.schedule(
      'compact-economy-cash-ledger',
      '* * * * *',
      'select economy_private.compact_cash_ledger_batch();'
    );
  else
    raise notice 'pg_cron is not installed; call economy_private.compact_cash_ledger_batch() once per minute.';
  end if;
end $$;

commit;
