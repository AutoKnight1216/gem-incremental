-- Make the live payable prize public while keeping the current draw's payout
-- basis points (tax) private. The preview uses the exact settlement formula,
-- including deterministic half-up rounding to the nearest $1,000.
begin;
set local check_function_bodies = off;

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
    'recentResults',v_recent,'unreadWin',v_unread);
end $$;

revoke all on function public.get_daily_lottery() from public,anon;
grant execute on function public.get_daily_lottery() to authenticated;

commit;
