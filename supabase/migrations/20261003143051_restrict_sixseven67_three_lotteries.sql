-- Temporarily prevent one identified account from entering three consecutive
-- lotteries. The restriction is enforced in the database, and any entries in
-- an affected open/locked draw are atomically refunded to their funding source.
begin;
set local check_function_bodies = off;

create table public.lottery_participation_restrictions (
  player_id uuid primary key references public.players(id) on delete restrict,
  blocked_from_draw_date date not null,
  blocked_through_draw_date date not null,
  eligible_at timestamptz not null,
  draw_count smallint not null check (draw_count > 0),
  message text not null,
  refunded_draw_id text references public.lottery_draws(id) on delete restrict,
  refunded_tickets bigint not null default 0 check (refunded_tickets >= 0),
  refunded_wallet numeric(30,0) not null default 0 check (refunded_wallet >= 0),
  refunded_bank numeric(30,0) not null default 0 check (refunded_bank >= 0),
  refunded_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (blocked_through_draw_date >= blocked_from_draw_date)
);

alter table public.lottery_participation_restrictions enable row level security;
revoke all on public.lottery_participation_restrictions from public, anon, authenticated, service_role;
grant select on public.lottery_participation_restrictions to service_role;

comment on table public.lottery_participation_restrictions is
  'Private, server-enforced draw-date restrictions. Player-facing details are exposed only through get_daily_lottery().';

insert into economy_private.cash_paths(function_name,category,direction) values
  ('refund_restricted_lottery_entries','lottery','source')
on conflict(function_name) do update set category=excluded.category,direction=excluded.direction;

-- Preserve the allocation finality rules while rejecting restricted entrants.
-- A transaction-local capability permits only the private refund routine to
-- remove an allocation after cutoff and before settlement.
create or replace function lottery_private.guard_final_allocation() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  v_status text;
  v_draw_date date;
  v_refund_capability text := nullif(current_setting('app.lottery_restriction_refund',true),'');
begin
  select status,draw_date into v_status,v_draw_date from public.lottery_draws
    where id=case when tg_op='INSERT' then new.draw_id else old.draw_id end;

  if tg_op='INSERT' then
    if v_status is distinct from 'open' then
      raise exception 'lottery_allocation_finalized';
    end if;
    if exists(
      select 1 from public.lottery_participation_restrictions r
      where r.player_id=new.player_id
        and v_draw_date between r.blocked_from_draw_date and r.blocked_through_draw_date
    ) then
      raise exception 'lottery_participation_restricted';
    end if;
    return new;
  end if;

  if tg_op='DELETE' then
    if v_status='open' then return old; end if;
    if v_status='locked'
      and v_refund_capability=old.draw_id||':'||old.player_id::text then
      return old;
    end if;
    raise exception 'lottery_allocation_finalized';
  end if;

  if new.draw_id is distinct from old.draw_id or new.player_id is distinct from old.player_id then
    raise exception 'lottery_allocation_identity_immutable';
  end if;

  if v_status='open' then
    if new.settlement_order_key is not null or new.settlement_position is not null
      or new.range_start is not null or new.range_end is not null or new.finalized_at is not null then
      raise exception 'lottery_allocation_settlement_fields_invalid';
    end if;
    if (new.ticket_count is distinct from old.ticket_count
        or new.purchase_total is distinct from old.purchase_total)
      and exists(
        select 1 from public.lottery_participation_restrictions r
        where r.player_id=new.player_id
          and v_draw_date between r.blocked_from_draw_date and r.blocked_through_draw_date
      ) then
      raise exception 'lottery_participation_restricted';
    end if;
    return new;
  end if;

  if v_status='settling'
    and old.settlement_order_key is null and old.settlement_position is null
    and old.range_start is null and old.range_end is null and old.finalized_at is null
    and new.settlement_order_key is not null and new.settlement_position is not null
    and new.range_start is not null and new.range_end is not null and new.finalized_at is not null
    and new.ticket_count is not distinct from old.ticket_count
    and new.purchase_total is not distinct from old.purchase_total then
    return new;
  end if;

  if new is distinct from old then
    raise exception 'lottery_allocation_finalized';
  end if;
  return new;
end $$;

create or replace function lottery_private.refund_restricted_lottery_entries(p_player_id uuid)
returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  v_restriction public.lottery_participation_restrictions%rowtype;
  v_entry record;
  v_wallet_refund numeric(30,0);
  v_bank_refund numeric(30,0);
  v_request_total numeric(30,0);
  v_ticket_count bigint;
  v_purchase_total numeric(30,0);
  v_refunded_tickets bigint:=0;
  v_refunded_wallet numeric(30,0):=0;
  v_refunded_bank numeric(30,0):=0;
begin
  select * into v_restriction
    from public.lottery_participation_restrictions
    where player_id=p_player_id for update;
  if not found then raise exception 'lottery_restriction_not_found'; end if;

  for v_entry in
    select d.id draw_id,d.status,d.draw_date
    from public.lottery_draws d
    where d.draw_date between v_restriction.blocked_from_draw_date and v_restriction.blocked_through_draw_date
      and d.status in ('open','locked')
    order by d.draw_at
    for update of d
  loop
    select ticket_count,purchase_total into v_ticket_count,v_purchase_total
    from public.lottery_allocations
    where draw_id=v_entry.draw_id and player_id=p_player_id for update;
    if not found then continue; end if;

    select
      coalesce(sum(cost) filter(where funding_source='wallet'),0),
      coalesce(sum(cost) filter(where funding_source='bank'),0),
      coalesce(sum(cost),0)
      into v_wallet_refund,v_bank_refund,v_request_total
    from public.lottery_purchase_requests
    where draw_id=v_entry.draw_id and player_id=p_player_id and outcome='purchased';

    if v_request_total is distinct from v_purchase_total then
      raise exception 'lottery_refund_purchase_audit_mismatch';
    end if;

    if v_wallet_refund>0 then
      perform set_config('app.economy_reference','lottery-restriction-refund:'||v_entry.draw_id||':'||p_player_id::text,true);
      perform set_config('app.economy_metadata',jsonb_build_object(
        'drawId',v_entry.draw_id,'playerId',p_player_id,'fundingSource','wallet',
        'kind','restricted_entry_refund')::text,true);
      update public.players set money=money+v_wallet_refund where id=p_player_id;
      if not found then raise exception 'lottery_refund_player_not_found'; end if;
    end if;

    if v_bank_refund>0 then
      perform set_config('app.economy_reference','lottery-restriction-refund:'||v_entry.draw_id||':'||p_player_id::text,true);
      perform set_config('app.economy_metadata',jsonb_build_object(
        'drawId',v_entry.draw_id,'playerId',p_player_id,'fundingSource','bank',
        'kind','restricted_entry_refund')::text,true);
      update public.bank_accounts set balance=balance+v_bank_refund,updated_at=clock_timestamp()
        where player_id=p_player_id;
      if not found then raise exception 'lottery_refund_bank_account_not_found'; end if;
      insert into public.bank_transactions(player_id,kind,amount,balance_after,loan_after,credit_after,memo)
      select p_player_id,'lottery_refund',v_bank_refund,b.balance,
        b.loan_principal+b.loan_interest_accrued,b.credit_score,
        'Daily Lottery restricted-entry refund'
      from public.bank_accounts b where b.player_id=p_player_id;
    end if;

    update public.lottery_purchase_requests set
      outcome='refunded_restriction',
      response=jsonb_build_object(
        'ok',false,'code','lottery_participation_restricted',
        'message',v_restriction.message,'refunded',true,'cost',cost,
        'fundingSource',funding_source,'eligibleAt',v_restriction.eligible_at)
      where draw_id=v_entry.draw_id and player_id=p_player_id and outcome='purchased';

    perform set_config('app.lottery_restriction_refund',v_entry.draw_id||':'||p_player_id::text,true);
    delete from public.lottery_allocations
      where draw_id=v_entry.draw_id and player_id=p_player_id;

    update public.lottery_draws set
      total_tickets=total_tickets-v_ticket_count,
      unique_participants=unique_participants-1,
      gross_revenue=gross_revenue-v_purchase_total
      where id=v_entry.draw_id
        and total_tickets>=v_ticket_count
        and unique_participants>=1
        and gross_revenue>=v_purchase_total;
    if not found then raise exception 'lottery_refund_draw_audit_mismatch'; end if;

    v_refunded_tickets:=v_refunded_tickets+v_ticket_count;
    v_refunded_wallet:=v_refunded_wallet+v_wallet_refund;
    v_refunded_bank:=v_refunded_bank+v_bank_refund;

    update public.lottery_participation_restrictions set
      refunded_draw_id=v_entry.draw_id,
      refunded_tickets=refunded_tickets+v_ticket_count,
      refunded_wallet=refunded_wallet+v_wallet_refund,
      refunded_bank=refunded_bank+v_bank_refund,
      refunded_at=clock_timestamp(),updated_at=clock_timestamp()
      where player_id=p_player_id;
  end loop;

  perform set_config('app.lottery_restriction_refund','',true);
  perform set_config('app.economy_reference','',true);
  perform set_config('app.economy_metadata','',true);
  return jsonb_build_object('tickets',v_refunded_tickets,
    'wallet',v_refunded_wallet,'bank',v_refunded_bank);
end $$;

revoke all on function lottery_private.refund_restricted_lottery_entries(uuid)
  from public,anon,authenticated,service_role;
grant execute on function lottery_private.refund_restricted_lottery_entries(uuid) to postgres;

create or replace function public.get_daily_lottery() returns jsonb
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
  v_restriction jsonb;
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
  select jsonb_build_object(
    'message',r.message,
    'eligibleAt',r.eligible_at,
    'blockedDrawsRemaining',greatest(0,(r.blocked_through_draw_date-v_draw.draw_date)+1)
  ) into v_restriction
  from public.lottery_participation_restrictions r
  where r.player_id=v_uid
    and v_draw.draw_date between r.blocked_from_draw_date and r.blocked_through_draw_date
    and v_now<r.eligible_at;
  select coalesce(jsonb_agg(jsonb_build_object(
    'date',d.draw_date,
    'winnerUsername',d.winner_username,
    'prize',coalesce(d.final_prize,0)::text,
    'hadWinner',d.winner_id is not null,
    'totalTickets',d.total_tickets::text,
    'winningTicketNumber',d.winning_integer::text,
    'winnerCost',case when d.winner_id is null then null else
      (d.winner_ticket_count::numeric*d.ticket_price)::text end,
    'taxPercent',case when d.winner_id is null then null else
      round((10000-d.payout_basis_points)::numeric/100,2)::text end,
    'profit',case when d.winner_id is null then null else
      (d.final_prize-(d.winner_ticket_count::numeric*d.ticket_price))::text end,
    'profitPercent',case when d.winner_id is null then null else
      round((d.final_prize-(d.winner_ticket_count::numeric*d.ticket_price))
        / nullif(d.winner_ticket_count::numeric*d.ticket_price,0)*100,2)::text end
  ) order by d.draw_date desc),'[]'::jsonb)
    into v_recent from (
      select * from public.lottery_draws where status='settled' order by draw_date desc limit 10
    ) d;
  select jsonb_build_object('drawId',d.id,'date',d.draw_date,'prize',d.final_prize)
    into v_unread from public.lottery_draws d where d.status='settled' and d.winner_id=v_uid
      and d.winner_notified_at is null order by d.draw_date desc limit 1;
  return jsonb_build_object('drawId',v_draw.id,'serverNow',v_now,'phase',v_phase,
    'ticketPrice',v_draw.ticket_price,'prizePool',
      (floor((((v_draw.gross_revenue*v_draw.payout_basis_points/10000)/1000)+0.5)*1000))::text,
    'salesOpenAt',v_draw.open_at,'cutoffAt',v_draw.cutoff_at,'drawAt',v_draw.draw_at,
    'nextSalesOpenAt',case when v_phase='transition' then v_draw.open_at else v_draw.next_open_at end,
    'ownTickets',v_own,'walletBalance',v_wallet,'bankBalance',v_bank,
    'recentResults',v_recent,'unreadWin',v_unread,
    'participationRestriction',v_restriction);
end $$;

revoke all on function public.get_daily_lottery() from public,anon;
grant execute on function public.get_daily_lottery() to authenticated;

do $seed_restriction$
declare
  v_player_id constant uuid:='316c668e-1ab3-4e5f-bad0-8cd964a41440';
  v_draw public.lottery_draws%rowtype;
  v_blocked_through date;
  v_eligible_at timestamptz;
begin
  if not exists(select 1 from public.players where id=v_player_id) then
    raise exception 'sixseven67_player_not_found';
  end if;

  perform public.maintain_daily_lottery();
  select * into v_draw from public.lottery_draws
    where status in ('open','locked') order by draw_at limit 1;
  if not found then
    select * into v_draw from public.lottery_draws
      where status='scheduled' order by open_at limit 1;
  end if;
  if v_draw.id is null then raise exception 'lottery_unavailable'; end if;

  v_blocked_through:=v_draw.draw_date+2;
  v_eligible_at:=(v_blocked_through+time '22:05') at time zone 'Asia/Singapore';

  insert into public.lottery_participation_restrictions(
    player_id,blocked_from_draw_date,blocked_through_draw_date,eligible_at,draw_count,message)
  values(v_player_id,v_draw.draw_date,v_blocked_through,v_eligible_at,3,
    'to ensure that everyone can have a chance at wining the lottery, you have been temporarily been prohibited from participating for 3 lotteries.')
  on conflict(player_id) do update set
    blocked_from_draw_date=excluded.blocked_from_draw_date,
    blocked_through_draw_date=excluded.blocked_through_draw_date,
    eligible_at=excluded.eligible_at,
    draw_count=excluded.draw_count,
    message=excluded.message,
    updated_at=clock_timestamp();

  perform lottery_private.refund_restricted_lottery_entries(v_player_id);
end $seed_restriction$;

commit;
