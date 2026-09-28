-- Give every future lottery draw a private, independently randomized entrant
-- ordering. Exact ranges are frozen at settlement for reproducible audits but
-- remain inaccessible to player-facing roles.
begin;
set local check_function_bodies = off;

alter table public.lottery_allocations
  add column settlement_order_key bytea,
  add column settlement_position integer,
  add column range_start bigint,
  add column range_end bigint;

alter table public.lottery_allocations
  add constraint lottery_allocations_settlement_range_check check (
    (settlement_order_key is null and settlement_position is null and range_start is null and range_end is null)
    or
    (settlement_order_key is not null and settlement_position is not null
      and range_start is not null and range_end is not null
      and settlement_position > 0 and range_start > 0
      and range_end >= range_start and range_end-range_start+1=ticket_count)
  );

create unique index lottery_allocations_settlement_position_key
  on public.lottery_allocations(draw_id,settlement_position)
  where settlement_position is not null;

comment on column public.lottery_allocations.settlement_order_key is
  'Private cryptographically random ordering key generated independently for each entrant when the draw settles.';
comment on column public.lottery_allocations.settlement_position is
  'Private frozen entrant position for the draw, ordered by settlement_order_key with player_id as a collision tie-breaker.';
comment on column public.lottery_allocations.range_start is
  'Private inclusive start of the entrant ticket interval frozen at settlement.';
comment on column public.lottery_allocations.range_end is
  'Private inclusive end of the entrant ticket interval frozen at settlement.';

create or replace function lottery_private.guard_final_allocation() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  v_status text;
begin
  if tg_op='INSERT' then
    select status into v_status from public.lottery_draws where id=new.draw_id;
    if v_status is distinct from 'open' then
      raise exception 'lottery_allocation_finalized';
    end if;
    return new;
  end if;

  select status into v_status from public.lottery_draws where id=old.draw_id;
  if tg_op='DELETE' then
    if v_status is distinct from 'open' then
      raise exception 'lottery_allocation_finalized';
    end if;
    return old;
  end if;

  if new.draw_id is distinct from old.draw_id or new.player_id is distinct from old.player_id then
    raise exception 'lottery_allocation_identity_immutable';
  end if;

  if v_status='open' then
    if new.settlement_order_key is not null or new.settlement_position is not null
      or new.range_start is not null or new.range_end is not null or new.finalized_at is not null then
      raise exception 'lottery_allocation_settlement_fields_invalid';
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

drop trigger lottery_allocation_final_guard on public.lottery_allocations;
create trigger lottery_allocation_final_guard
before insert or update or delete on public.lottery_allocations
for each row execute function lottery_private.guard_final_allocation();

create or replace function public.settle_lottery_draw(p_draw_id text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  v_draw public.lottery_draws%rowtype;
  v_total bigint;
  v_participants integer;
  v_covered bigint;
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

  -- Generate an independent private ordering key for every entrant, then freeze
  -- exact contiguous ranges before generating the winning integer.
  with seeded as materialized (
    select player_id,ticket_count,extensions.gen_random_bytes(16) settlement_order_key
    from public.lottery_allocations where draw_id=v_draw.id
  ), ranked as (
    select player_id,settlement_order_key,
      row_number() over(order by settlement_order_key,player_id)::integer settlement_position,
      coalesce(sum(ticket_count) over(order by settlement_order_key,player_id
        rows between unbounded preceding and 1 preceding),0)+1 range_start,
      sum(ticket_count) over(order by settlement_order_key,player_id
        rows between unbounded preceding and current row) range_end
    from seeded
  )
  update public.lottery_allocations a set
    settlement_order_key=ranked.settlement_order_key,
    settlement_position=ranked.settlement_position,
    range_start=ranked.range_start,
    range_end=ranked.range_end,
    finalized_at=clock_timestamp()
  from ranked where a.draw_id=v_draw.id and a.player_id=ranked.player_id;

  select max(range_end) into v_covered from public.lottery_allocations where draw_id=v_draw.id;
  if v_covered is distinct from v_total then raise exception 'lottery_allocation_range_invalid'; end if;

  v_winning := lottery_private.secure_random_bigint(v_total);
  select a.player_id,a.ticket_count into v_winner,v_winner_tickets
    from public.lottery_allocations a
    where a.draw_id=v_draw.id and v_winning between a.range_start and a.range_end
    order by a.settlement_position limit 1;
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

commit;
