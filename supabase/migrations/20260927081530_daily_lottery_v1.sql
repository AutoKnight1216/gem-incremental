-- Daily Lottery V1. All clocks, money movement, winner selection, and public
-- response shaping are server-authoritative. The public RPCs deliberately
-- expose qualitative activity only; exact draw/accounting data remains admin-only.
begin;
set local check_function_bodies = off;

create extension if not exists pgcrypto with schema extensions;

create schema if not exists lottery_private;
revoke all on schema lottery_private from public, anon, authenticated;

create table public.lottery_draws (
  id text primary key,
  draw_date date not null unique,
  open_at timestamptz not null,
  cutoff_at timestamptz not null,
  draw_at timestamptz not null,
  next_open_at timestamptz not null,
  status text not null check (status in ('scheduled','open','locked','settling','settled')),
  ticket_price bigint not null default 10000 check (ticket_price = 10000),
  payout_basis_points smallint not null check (payout_basis_points between 8000 and 9000),
  total_tickets bigint not null default 0 check (total_tickets >= 0),
  unique_participants integer not null default 0 check (unique_participants >= 0),
  gross_revenue numeric(30,0) not null default 0 check (gross_revenue >= 0),
  winning_integer bigint,
  winner_id uuid references public.players(id) on delete restrict,
  winner_username text,
  winner_ticket_count bigint,
  final_prize numeric(30,0),
  effective_burn numeric(30,0),
  final_activity_band text,
  settlement_reference text unique,
  settled_at timestamptz,
  winner_notified_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (open_at < cutoff_at and cutoff_at < draw_at and draw_at < next_open_at),
  check ((winning_integer is null and winner_id is null) or (winning_integer between 1 and total_tickets))
);

create table public.lottery_allocations (
  draw_id text not null references public.lottery_draws(id) on delete restrict,
  player_id uuid not null references public.players(id) on delete restrict,
  ticket_count bigint not null check (ticket_count > 0),
  purchase_total numeric(30,0) not null check (purchase_total > 0),
  finalized_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  primary key (draw_id, player_id)
);

create table public.lottery_purchase_requests (
  request_id uuid not null,
  player_id uuid not null references public.players(id) on delete restrict,
  draw_id text references public.lottery_draws(id) on delete restrict,
  quantity bigint,
  funding_source text,
  cost numeric(30,0),
  outcome text not null,
  response jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (request_id, player_id),
  check (funding_source is null or funding_source in ('wallet','bank'))
);

create index lottery_draws_status_time_idx on public.lottery_draws(status, draw_at);
create index lottery_draws_recent_idx on public.lottery_draws(draw_date desc) where status='settled';
create index lottery_allocations_player_idx on public.lottery_allocations(player_id, draw_id);
create index lottery_purchase_rate_idx on public.lottery_purchase_requests(player_id, created_at desc);
create index lottery_purchase_draw_idx on public.lottery_purchase_requests(draw_id, outcome, created_at);

alter table public.lottery_draws enable row level security;
alter table public.lottery_allocations enable row level security;
alter table public.lottery_purchase_requests enable row level security;
revoke all on public.lottery_draws, public.lottery_allocations, public.lottery_purchase_requests
  from public, anon, authenticated, service_role;
grant select on public.lottery_draws, public.lottery_allocations, public.lottery_purchase_requests to service_role;

comment on column public.lottery_draws.payout_basis_points is
  'Private immutable C, sampled uniformly from the 1001 basis-point values 8000..9000 before sales open.';
comment on column public.lottery_draws.final_prize is
  'gross_revenue * payout_basis_points / 10000, rounded to the nearest $1,000 with positive half values rounded up.';

create function lottery_private.activity_band(p_total bigint) returns text
language sql immutable strict set search_path='' as $$
  select case
    when p_total=0 then 'The lottery is empty.'
    when p_total<100 then 'The lottery is just getting started.'
    when p_total<1000 then 'The lottery is picking up.'
    when p_total<5000 then 'Competition is heating up.'
    when p_total<20000 then 'The lottery is getting crowded.'
    when p_total<50000 then 'The lottery is packed.'
    when p_total<100000 then 'The lottery is overflowing with entries.'
    when p_total<250000 then 'The lottery is absolutely stacked.'
    else 'Good luck.' end;
$$;

-- Rejection sampling over 56 cryptographically random bits avoids modulo bias
-- for every lottery range while keeping the value inside signed bigint.
create function lottery_private.secure_random_bigint(p_upper bigint) returns bigint
language plpgsql volatile security definer set search_path='' as $$
declare
  v_space numeric := 72057594037927936; -- 2^56
  v_limit numeric;
  v_candidate numeric;
begin
  if p_upper is null or p_upper < 1 or p_upper > 72057594037927936 then
    raise exception 'lottery_random_range_invalid';
  end if;
  v_limit := v_space - mod(v_space, p_upper::numeric);
  loop
    v_candidate := (('x'||encode(extensions.gen_random_bytes(7),'hex'))::bit(56)::bigint)::numeric;
    exit when v_candidate < v_limit;
  end loop;
  return (mod(v_candidate, p_upper::numeric) + 1)::bigint;
end $$;
revoke all on function lottery_private.activity_band(bigint) from public,anon,authenticated;
revoke all on function lottery_private.secure_random_bigint(bigint) from public,anon,authenticated;

create function lottery_private.guard_draw_secrets() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.id is distinct from old.id
    or new.draw_date is distinct from old.draw_date
    or new.open_at is distinct from old.open_at
    or new.cutoff_at is distinct from old.cutoff_at
    or new.draw_at is distinct from old.draw_at
    or new.next_open_at is distinct from old.next_open_at
    or new.ticket_price is distinct from old.ticket_price
    or new.payout_basis_points is distinct from old.payout_basis_points then
    raise exception 'lottery_draw_immutable';
  end if;
  new.updated_at := clock_timestamp();
  return new;
end $$;
create trigger lottery_draw_secret_guard before update on public.lottery_draws
for each row execute function lottery_private.guard_draw_secrets();

create function lottery_private.guard_final_allocation() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.ticket_count is distinct from old.ticket_count
     and not exists(select 1 from public.lottery_draws d where d.id=old.draw_id and d.status='open') then
    raise exception 'lottery_allocation_finalized';
  end if;
  return new;
end $$;
create trigger lottery_allocation_final_guard before update on public.lottery_allocations
for each row execute function lottery_private.guard_final_allocation();

-- Extend the existing trigger-based cash ledger with transaction-local detail.
-- Existing callers behave exactly as before because unset settings are empty.
-- Abort instead of replacing a newer deployed accounting implementation.
do $capture_cash_guard$ begin
  if md5(pg_get_functiondef('economy_private.capture_cash()'::regprocedure)) <> 'ddbec6fd65eac019478769818c491c52' then
    raise exception 'Economy cash capture baseline changed. Re-audit Daily Lottery attribution before deployment.';
  end if;
end $capture_cash_guard$;
create or replace function economy_private.capture_cash() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_old numeric := 0; v_new numeric := 0; v_delta numeric; v_player uuid;
  v_account text := tg_argv[0]; v_context text; v_match text[];
  v_function text; v_category text; v_direction text; v_subcategory text;
  v_reference text := nullif(current_setting('app.economy_reference',true),'');
  v_extra jsonb := coalesce(nullif(current_setting('app.economy_metadata',true),'')::jsonb,'{}'::jsonb);
begin
  if tg_op <> 'INSERT' then
    if v_account='wallet' then v_old:=coalesce(old.money::numeric,0); v_player:=old.id;
    else v_old:=coalesce(old.balance::numeric,0); v_player:=old.player_id; end if;
  end if;
  if tg_op <> 'DELETE' then
    if v_account='wallet' then v_new:=coalesce(new.money::numeric,0); v_player:=new.id;
    else v_new:=coalesce(new.balance::numeric,0); v_player:=new.player_id; end if;
  end if;
  v_delta := v_new-v_old;
  if v_delta=0 then return null; end if;
  get diagnostics v_context = pg_context;
  for v_match in select regexp_matches(v_context,'(?:PL/pgSQL|SQL) function (?:public\.)?([a-z_][a-z_0-9]*)\(', 'g') loop
    select category,direction into v_category,v_direction
      from economy_private.cash_paths where function_name=v_match[1];
    if found then v_function:=v_match[1]; exit; end if;
  end loop;
  v_subcategory:=coalesce(v_function,lower(tg_op));
  if v_function='bank_touch' then
    v_category:=case when v_delta>0 then 'bank_interest' else 'bank_loan_seizure' end;
  end if;
  if v_category is null then
    v_category:=case tg_op when 'INSERT' then 'account_initialization' when 'DELETE' then 'account_removal' else 'unattributed' end;
  end if;
  v_direction:=coalesce(v_direction,case when v_delta>0 then 'source' else 'sink' end);
  insert into public.economy_cash_ledger(player_id,account,amount,direction,category,subcategory,reference,metadata)
  values(v_player,v_account,v_delta,v_direction,v_category,v_subcategory,coalesce(v_reference,v_function),
    jsonb_build_object('table',tg_table_name,'operation',tg_op,'before',v_old,'after',v_new,
      'attribution',case when v_function is null then 'balance_only' else 'database_function' end)||v_extra);
  return null;
end $$;

insert into economy_private.cash_paths(function_name,category,direction) values
  ('purchase_lottery_tickets','lottery','sink'),
  ('settle_lottery_draw','lottery','source')
on conflict(function_name) do update set category=excluded.category,direction=excluded.direction;

create function lottery_private.create_draw(p_draw_date date) returns text
language plpgsql security definer set search_path='' as $$
declare
  v_id text := 'LOTTERY-'||to_char(p_draw_date,'YYYY-MM-DD');
  v_open timestamptz := ((p_draw_date-1)+time '22:05') at time zone 'Asia/Singapore';
  v_cutoff timestamptz := (p_draw_date+time '21:55') at time zone 'Asia/Singapore';
  v_draw timestamptz := (p_draw_date+time '22:00') at time zone 'Asia/Singapore';
  v_next timestamptz := (p_draw_date+time '22:05') at time zone 'Asia/Singapore';
  v_now timestamptz := clock_timestamp();
begin
  insert into public.lottery_draws(id,draw_date,open_at,cutoff_at,draw_at,next_open_at,status,payout_basis_points)
  values(v_id,p_draw_date,v_open,v_cutoff,v_draw,v_next,
    case when v_now<v_open then 'scheduled' when v_now<v_cutoff then 'open' else 'locked' end,
    7999+lottery_private.secure_random_bigint(1001))
  on conflict(draw_date) do nothing;
  return v_id;
end $$;
revoke all on function lottery_private.create_draw(date) from public,anon,authenticated;

create function public.settle_lottery_draw(p_draw_id text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  v_draw public.lottery_draws%rowtype;
  v_total bigint;
  v_participants integer;
  v_winning bigint;
  v_winner uuid;
  v_winner_tickets bigint;
  v_username text;
  v_prize numeric(30,0);
  v_reference text;
begin
  select * into v_draw from public.lottery_draws where id=p_draw_id for update;
  if not found then raise exception 'lottery_draw_not_found'; end if;
  if v_draw.status='settled' then
    return jsonb_build_object('drawId',v_draw.id,'status','settled','settledAt',v_draw.settled_at);
  end if;
  if clock_timestamp()<v_draw.draw_at then raise exception 'lottery_draw_not_due'; end if;

  update public.lottery_draws set status='settling' where id=v_draw.id;
  update public.lottery_allocations set finalized_at=coalesce(finalized_at,clock_timestamp()) where draw_id=v_draw.id;
  select coalesce(sum(ticket_count),0),count(*)::integer into v_total,v_participants
    from public.lottery_allocations where draw_id=v_draw.id;
  update public.lottery_draws set total_tickets=v_total,unique_participants=v_participants,
    gross_revenue=v_total::numeric*v_draw.ticket_price where id=v_draw.id;

  v_reference := 'lottery-payout:'||v_draw.id;
  if v_total=0 then
    update public.lottery_draws set status='settled',winning_integer=null,winner_id=null,
      winner_username=null,winner_ticket_count=null,final_prize=0,effective_burn=0,
      final_activity_band=lottery_private.activity_band(0),settlement_reference=v_reference,
      settled_at=clock_timestamp() where id=v_draw.id;
    return jsonb_build_object('drawId',v_draw.id,'status','settled','winner',null,'prize',0);
  end if;

  v_winning := lottery_private.secure_random_bigint(v_total);
  select ranked.player_id,ranked.ticket_count into v_winner,v_winner_tickets
  from (
    select a.player_id,a.ticket_count,
      sum(a.ticket_count) over(order by a.player_id rows between unbounded preceding and current row) cumulative
    from public.lottery_allocations a where a.draw_id=v_draw.id
  ) ranked where ranked.cumulative>=v_winning order by ranked.player_id limit 1;
  select p.username into v_username from public.players p where p.id=v_winner;
  if v_winner is null or v_username is null then raise exception 'lottery_winner_unavailable'; end if;

  -- Deterministic positive half-up rounding to the nearest whole $1,000.
  v_prize := floor((((v_total::numeric*v_draw.ticket_price)*v_draw.payout_basis_points/10000)/1000)+0.5)*1000;
  perform set_config('app.economy_reference',v_reference,true);
  perform set_config('app.economy_metadata',jsonb_build_object('drawId',v_draw.id,'kind','payout')::text,true);
  update public.players set money=money+v_prize,
    lifetime_earnings=coalesce(lifetime_earnings,0)+v_prize where id=v_winner;
  if not found then raise exception 'lottery_winner_unavailable'; end if;

  update public.lottery_draws set status='settled',winning_integer=v_winning,winner_id=v_winner,
    winner_username=v_username,winner_ticket_count=v_winner_tickets,final_prize=v_prize,
    effective_burn=(v_total::numeric*v_draw.ticket_price)-v_prize,
    final_activity_band=lottery_private.activity_band(v_total),settlement_reference=v_reference,
    settled_at=clock_timestamp() where id=v_draw.id;
  return jsonb_build_object('drawId',v_draw.id,'status','settled','winnerId',v_winner,
    'winnerUsername',v_username,'prize',v_prize,'settledAt',clock_timestamp());
end $$;
revoke all on function public.settle_lottery_draw(text) from public,anon,authenticated,service_role;
grant execute on function public.settle_lottery_draw(text) to postgres;

create function public.maintain_daily_lottery() returns void
language plpgsql security definer set search_path='' as $$
declare
  v_now timestamptz:=clock_timestamp();
  v_local timestamp:=v_now at time zone 'Asia/Singapore';
  v_target date;
  v_due record;
begin
  update public.lottery_draws set status='open'
    where status='scheduled' and open_at<=v_now and cutoff_at>v_now;
  update public.lottery_draws set status='locked'
    where status='open' and cutoff_at<=v_now;
  for v_due in select id from public.lottery_draws
    where status<>'settled' and draw_at<=v_now order by draw_at for update skip locked loop
    perform public.settle_lottery_draw(v_due.id);
  end loop;
  v_target := case when v_local::time>=time '22:00' then v_local::date+1 else v_local::date end;
  perform lottery_private.create_draw(v_target);
  update public.lottery_draws set status='open'
    where status='scheduled' and open_at<=v_now and cutoff_at>v_now;
end $$;
revoke all on function public.maintain_daily_lottery() from public,anon,authenticated,service_role;
grant execute on function public.maintain_daily_lottery() to postgres;

create function public.purchase_lottery_tickets(
  p_quantity bigint,
  p_funding_source text,
  p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  v_uid uuid:=auth.uid();
  v_now timestamptz:=clock_timestamp();
  v_draw public.lottery_draws%rowtype;
  v_existing jsonb;
  v_cost numeric(30,0);
  v_wallet numeric;
  v_bank numeric;
  v_own bigint;
  v_is_new boolean:=false;
  v_response jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_request_id is null then raise exception 'lottery_request_id_required'; end if;
  -- Serialize identical retry keys before the idempotency read. Independent
  -- purchases still serialize only on the shared draw totals row below.
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text||':'||p_request_id::text,0));
  select response into v_existing from public.lottery_purchase_requests
    where request_id=p_request_id and player_id=v_uid;
  if found then return v_existing; end if;

  perform public.maintain_daily_lottery();
  select * into v_draw from public.lottery_draws
    where status='open' and open_at<=v_now and cutoff_at>v_now
    order by draw_at limit 1 for update;
  if not found then
    v_response:=jsonb_build_object('ok',false,'code','lottery_closed','message','Entries are closed. You were not charged.');
    insert into public.lottery_purchase_requests(request_id,player_id,quantity,funding_source,outcome,response)
      values(p_request_id,v_uid,p_quantity,p_funding_source,'rejected_closed',v_response);
    return v_response;
  end if;
  if p_quantity is null or p_quantity<1 or p_quantity>900000000000 then
    v_response:=jsonb_build_object('ok',false,'code','lottery_invalid_quantity','message','Enter a valid whole number of tickets.');
    insert into public.lottery_purchase_requests(request_id,player_id,draw_id,quantity,funding_source,outcome,response)
      values(p_request_id,v_uid,v_draw.id,p_quantity,p_funding_source,'rejected_invalid',v_response);
    return v_response;
  end if;
  if p_funding_source is null or p_funding_source not in ('wallet','bank') then
    v_response:=jsonb_build_object('ok',false,'code','lottery_invalid_funding_source','message','Choose wallet or bank.');
    insert into public.lottery_purchase_requests(request_id,player_id,draw_id,quantity,funding_source,outcome,response)
      values(p_request_id,v_uid,v_draw.id,p_quantity,p_funding_source,'rejected_invalid',v_response);
    return v_response;
  end if;
  if (select count(*) from public.lottery_purchase_requests
      where player_id=v_uid and created_at>v_now-interval '10 seconds')>=12 then
    v_response:=jsonb_build_object('ok',false,'code','lottery_rate_limited','message','Too many purchase attempts. Wait a moment and try again.');
    insert into public.lottery_purchase_requests(request_id,player_id,draw_id,quantity,funding_source,outcome,response)
      values(p_request_id,v_uid,v_draw.id,p_quantity,p_funding_source,'rejected_rate_limit',v_response);
    return v_response;
  end if;

  v_cost:=p_quantity::numeric*v_draw.ticket_price;
  if p_funding_source='wallet' then
    perform set_config('app.economy_reference','lottery-purchase:'||p_request_id::text,true);
    perform set_config('app.economy_metadata',jsonb_build_object('drawId',v_draw.id,'requestId',p_request_id,'quantity',p_quantity,'kind','ticket_purchase')::text,true);
    update public.players set money=money-v_cost where id=v_uid and money>=v_cost returning money into v_wallet;
    if not found then
      v_response:=jsonb_build_object('ok',false,'code','lottery_insufficient_wallet','message','Your wallet cannot cover the full purchase. You were not charged.');
      insert into public.lottery_purchase_requests(request_id,player_id,draw_id,quantity,funding_source,cost,outcome,response)
        values(p_request_id,v_uid,v_draw.id,p_quantity,p_funding_source,v_cost,'rejected_funds',v_response);
      return v_response;
    end if;
    select coalesce(balance,0) into v_bank from public.bank_accounts where player_id=v_uid;
  else
    perform public.bank_touch(v_uid);
    perform set_config('app.economy_reference','lottery-purchase:'||p_request_id::text,true);
    perform set_config('app.economy_metadata',jsonb_build_object('drawId',v_draw.id,'requestId',p_request_id,'quantity',p_quantity,'kind','ticket_purchase')::text,true);
    update public.bank_accounts set balance=balance-v_cost,updated_at=v_now
      where player_id=v_uid and balance>=v_cost returning balance into v_bank;
    if not found then
      v_response:=jsonb_build_object('ok',false,'code','lottery_insufficient_bank','message','Your bank balance cannot cover the full purchase. You were not charged.');
      insert into public.lottery_purchase_requests(request_id,player_id,draw_id,quantity,funding_source,cost,outcome,response)
        values(p_request_id,v_uid,v_draw.id,p_quantity,p_funding_source,v_cost,'rejected_funds',v_response);
      return v_response;
    end if;
    insert into public.bank_transactions(player_id,kind,amount,balance_after,loan_after,credit_after,memo)
    select v_uid,'lottery',v_cost,b.balance,b.loan_principal+b.loan_interest_accrued,b.credit_score,
      'Daily Lottery tickets' from public.bank_accounts b where b.player_id=v_uid;
    select money into v_wallet from public.players where id=v_uid;
  end if;

  select ticket_count into v_own from public.lottery_allocations
    where draw_id=v_draw.id and player_id=v_uid for update;
  if found then
    update public.lottery_allocations set ticket_count=ticket_count+p_quantity,
      purchase_total=purchase_total+v_cost,updated_at=v_now
      where draw_id=v_draw.id and player_id=v_uid returning ticket_count into v_own;
  else
    insert into public.lottery_allocations(draw_id,player_id,ticket_count,purchase_total)
      values(v_draw.id,v_uid,p_quantity,v_cost) returning ticket_count into v_own;
    v_is_new:=true;
  end if;
  update public.lottery_draws set total_tickets=total_tickets+p_quantity,
    unique_participants=unique_participants+case when v_is_new then 1 else 0 end,
    gross_revenue=gross_revenue+v_cost where id=v_draw.id returning * into v_draw;

  v_response:=jsonb_build_object('ok',true,'code','purchased','drawId',v_draw.id,
    'ticketsPurchased',p_quantity,'cost',v_cost,'fundingSource',p_funding_source,
    'ownTickets',v_own,'activityBand',lottery_private.activity_band(v_draw.total_tickets),
    'walletBalance',coalesce(v_wallet,0),'bankBalance',coalesce(v_bank,0));
  insert into public.lottery_purchase_requests(request_id,player_id,draw_id,quantity,funding_source,cost,outcome,response)
    values(p_request_id,v_uid,v_draw.id,p_quantity,p_funding_source,v_cost,'purchased',v_response);
  return v_response;
end $$;

create function public.get_daily_lottery() returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  v_uid uuid:=auth.uid();
  v_now timestamptz:=clock_timestamp();
  v_draw public.lottery_draws%rowtype;
  v_own bigint:=0;
  v_wallet numeric:=0;
  v_bank numeric:=0;
  v_phase text;
  v_recent jsonb;
  v_unread jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.maintain_daily_lottery();
  select * into v_draw from public.lottery_draws
    where status in ('open','locked') order by draw_at limit 1;
  if not found then
    select * into v_draw from public.lottery_draws where status='scheduled' order by open_at limit 1;
  end if;
  if v_draw.id is null then raise exception 'lottery_unavailable'; end if;
  v_phase:=case when v_draw.status='open' and v_now<v_draw.cutoff_at then 'open'
    when v_draw.status='locked' and v_now<v_draw.draw_at then 'locked' else 'transition' end;
  select coalesce(ticket_count,0) into v_own from public.lottery_allocations
    where draw_id=v_draw.id and player_id=v_uid;
  select coalesce(money,0) into v_wallet from public.players where id=v_uid;
  select coalesce(balance,0) into v_bank from public.bank_accounts where player_id=v_uid;
  select coalesce(jsonb_agg(jsonb_build_object('date',d.draw_date,'winnerUsername',d.winner_username,
    'prize',coalesce(d.final_prize,0),'hadWinner',d.winner_id is not null) order by d.draw_date desc),'[]'::jsonb)
    into v_recent from (select * from public.lottery_draws where status='settled' order by draw_date desc limit 10) d;
  select jsonb_build_object('drawId',d.id,'date',d.draw_date,'prize',d.final_prize)
    into v_unread from public.lottery_draws d where d.status='settled' and d.winner_id=v_uid
      and d.winner_notified_at is null order by d.draw_date desc limit 1;
  return jsonb_build_object('serverNow',v_now,'phase',v_phase,'ticketPrice',v_draw.ticket_price,
    'salesOpenAt',v_draw.open_at,'cutoffAt',v_draw.cutoff_at,'drawAt',v_draw.draw_at,
    'nextSalesOpenAt',case when v_phase='transition' then v_draw.open_at else v_draw.next_open_at end,
    'ownTickets',v_own,'activityBand',lottery_private.activity_band(v_draw.total_tickets),
    'walletBalance',v_wallet,'bankBalance',v_bank,'recentResults',v_recent,'unreadWin',v_unread);
end $$;

create function public.acknowledge_lottery_win(p_draw_id text) returns boolean
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  update public.lottery_draws set winner_notified_at=coalesce(winner_notified_at,clock_timestamp())
    where id=p_draw_id and status='settled' and winner_id=v_uid;
  return found;
end $$;

create function public.admin_get_lottery_analytics(p_period text default '24H') returns jsonb
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
  ), ledger_totals as materialized (
    select coalesce(-sum(amount) filter(where direction='sink'),0) all_sinks,
      coalesce(sum(amount) filter(where category='gem_sales' and amount>0),0) gem_sales
    from public.economy_cash_ledger l where l.created_at between v_from and v_now
      and not exists(select 1 from public.system_account_exclusions e where e.player_id=l.player_id and e.exclude_from_economy)
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
end $$;

revoke all on function public.purchase_lottery_tickets(bigint,text,uuid) from public,anon;
revoke all on function public.get_daily_lottery() from public,anon;
revoke all on function public.acknowledge_lottery_win(text) from public,anon;
revoke all on function public.admin_get_lottery_analytics(text) from public,anon;
grant execute on function public.purchase_lottery_tickets(bigint,text,uuid) to authenticated;
grant execute on function public.get_daily_lottery() to authenticated;
grant execute on function public.acknowledge_lottery_win(text) to authenticated;
grant execute on function public.admin_get_lottery_analytics(text) to authenticated;

insert into public.game_section_settings(id,label,short_label,icon,description,enabled,sort_order)
values('lottery','Daily Lottery','Lottery','dice','A private-pool daily lottery drawn at 10:00 PM Singapore time.',true,325)
on conflict(id) do nothing;

-- Seed the next relevant draw without inventing a completed historical draw.
select lottery_private.create_draw(
  case when (clock_timestamp() at time zone 'Asia/Singapore')::time>=time '22:00'
    then (clock_timestamp() at time zone 'Asia/Singapore')::date+1
    else (clock_timestamp() at time zone 'Asia/Singapore')::date end
);

do $$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    perform cron.unschedule('maintain-daily-lottery')
      where exists(select 1 from cron.job where jobname='maintain-daily-lottery');
    perform cron.schedule('maintain-daily-lottery','* * * * *','select public.maintain_daily_lottery();');
  else
    raise notice 'pg_cron is not installed; schedule public.maintain_daily_lottery() every minute manually.';
  end if;
end $$;

commit;
