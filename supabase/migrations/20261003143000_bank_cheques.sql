-- Player-to-player cheques. The sender's wallet funds the cheque immediately;
-- the named recipient receives the face value less 7.5% when they cash it.
-- An uncashed cheque may be cancelled for a full refund. All three actions
-- are single database transactions and require the caller's auth.uid().
begin;
set local check_function_bodies = off;

create table public.bank_cheques (
  id bigint generated always as identity primary key,
  -- Keep the record if either auth account is deleted: a recipient deletion
  -- must not silently destroy funds the sender can still cancel.
  sender_id uuid not null,
  recipient_id uuid not null,
  sender_name text not null,
  recipient_name text not null,
  face_amount numeric(18,2) not null check (face_amount >= 1 and face_amount <= 1000000000000 and face_amount = trunc(face_amount)),
  tax_amount numeric(18,2) not null check (tax_amount >= 0),
  net_amount numeric(18,2) not null check (net_amount > 0),
  status text not null default 'pending' check (status in ('pending','cashed','cancelled')),
  created_at timestamptz not null default now(),
  cashed_at timestamptz,
  cancelled_at timestamptz,
  constraint bank_cheque_different_players check (sender_id <> recipient_id),
  constraint bank_cheque_amounts_balance check (face_amount = tax_amount + net_amount),
  constraint bank_cheque_status_time check (
    (status = 'pending' and cashed_at is null and cancelled_at is null) or
    (status = 'cashed' and cashed_at is not null and cancelled_at is null) or
    (status = 'cancelled' and cancelled_at is not null and cashed_at is null)
  )
);
create index bank_cheques_incoming_idx on public.bank_cheques(recipient_id, created_at desc);
create index bank_cheques_outgoing_idx on public.bank_cheques(sender_id, created_at desc);
alter table public.bank_cheques enable row level security;
revoke all on public.bank_cheques from public, anon, authenticated;
grant select, insert, update on public.bank_cheques to service_role;

-- Classify wallet movements as transfers. Clearing entries hold the full
-- cheque while pending, then release it on cash/cancel. Cashing reclassifies
-- the withheld amount as a tax sink, so transfer accounting stays at zero.
insert into economy_private.cash_paths(function_name, category, direction) values
  ('bank_issue_cheque', 'cheque_escrow', 'transfer'),
  ('bank_cash_cheque', 'cheque_escrow', 'transfer'),
  ('bank_cancel_cheque', 'cheque_escrow', 'transfer')
on conflict (function_name) do update
set category = excluded.category, direction = excluded.direction;

create function public.bank_list_cheques(p_incoming_offset integer default 0, p_outgoing_offset integer default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_incoming_offset integer := greatest(0, coalesce(p_incoming_offset, 0));
  v_outgoing_offset integer := greatest(0, coalesce(p_outgoing_offset, 0));
begin
  if v_uid is null then raise exception 'unauthenticated'; end if;
  return jsonb_build_object(
    'taxRate', 0.075,
    'incoming', coalesce((
      select jsonb_agg(to_jsonb(c)) from (
        select id, sender_name, face_amount, tax_amount, net_amount, status, created_at, cashed_at, cancelled_at
        from public.bank_cheques
        where recipient_id = v_uid
        order by (status = 'pending') desc, created_at desc
        limit 31 offset v_incoming_offset
      ) c
    ), '[]'::jsonb),
    'outgoing', coalesce((
      select jsonb_agg(to_jsonb(c)) from (
        select id, recipient_name, face_amount, tax_amount, net_amount, status, created_at, cashed_at, cancelled_at
        from public.bank_cheques
        where sender_id = v_uid
        order by (status = 'pending') desc, created_at desc
        limit 31 offset v_outgoing_offset
      ) c
    ), '[]'::jsonb)
  );
end;
$$;

create function public.bank_issue_cheque(p_recipient_username text, p_amount double precision)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_username text := btrim(coalesce(p_recipient_username, ''));
  v_matches uuid[];
  v_recipient uuid;
  v_sender_name text;
  v_recipient_name text;
  v_face numeric(18,2);
  v_tax numeric(18,2);
  v_net numeric(18,2);
  v_wallet double precision;
  v_acct public.bank_accounts%rowtype;
  v_id bigint;
  v_pending integer;
begin
  if v_uid is null then raise exception 'unauthenticated'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000000000 or p_amount <> trunc(p_amount) then
    raise exception 'bank_cheque_invalid_amount';
  end if;
  if length(v_username) < 3 or length(v_username) > 20 or v_username !~ '^[A-Za-z0-9_]+$' then
    raise exception 'bank_cheque_invalid_recipient';
  end if;

  select array_agg(p.id) into v_matches
  from public.players p
  join auth.users u on u.id = p.id
  where lower(p.username) = lower(v_username);
  if coalesce(array_length(v_matches, 1), 0) = 0 then raise exception 'bank_cheque_recipient_not_found'; end if;
  if array_length(v_matches, 1) > 1 then raise exception 'bank_cheque_recipient_ambiguous'; end if;
  v_recipient := v_matches[1];
  if v_recipient = v_uid then raise exception 'bank_cheque_self_transfer'; end if;

  select username into v_sender_name from public.players where id = v_uid;
  select username into v_recipient_name from public.players where id = v_recipient;
  if v_sender_name is null then raise exception 'bank_cheque_sender_missing'; end if;

  v_face := p_amount::numeric;
  v_tax := round(v_face * 0.075, 2);
  v_net := v_face - v_tax;
  perform public.bank_touch(v_uid);
  select * into v_acct from public.bank_accounts where player_id = v_uid;

  update public.players set money = money - v_face::double precision
  where id = v_uid and money >= v_face::double precision
  returning money into v_wallet;
  if v_wallet is null then raise exception 'bank_insufficient_wallet'; end if;

  -- The wallet row lock serializes parallel issue requests for this sender.
  select count(*) into v_pending from public.bank_cheques
  where sender_id = v_uid and status = 'pending';
  if v_pending >= 20 then raise exception 'bank_cheque_limit'; end if;

  insert into public.bank_cheques(sender_id, recipient_id, sender_name, recipient_name, face_amount, tax_amount, net_amount)
  values (v_uid, v_recipient, v_sender_name, v_recipient_name, v_face, v_tax, v_net)
  returning id into v_id;
  insert into public.economy_cash_ledger
    (player_id, account, amount, direction, category, subcategory, reference, metadata)
  values (v_uid, 'clearing', v_face, 'transfer', 'cheque_escrow', 'fund',
          v_id::text, '{"accountingOnly":true}'::jsonb);
  insert into public.bank_transactions(player_id, kind, amount, balance_after, loan_after, credit_after, memo)
  values (v_uid, 'cheque_issue', v_face, v_acct.balance,
          v_acct.loan_principal + v_acct.loan_interest_accrued, v_acct.credit_score,
          'Cheque #' || v_id || ' to ' || v_recipient_name);
  return jsonb_build_object('id', v_id, 'faceAmount', v_face, 'taxAmount', v_tax,
                            'netAmount', v_net, 'recipient', v_recipient_name);
end;
$$;

create function public.bank_cash_cheque(p_cheque_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_cheque public.bank_cheques%rowtype;
  v_wallet double precision;
  v_acct public.bank_accounts%rowtype;
begin
  if v_uid is null then raise exception 'unauthenticated'; end if;
  select * into v_cheque from public.bank_cheques
  where id = p_cheque_id and recipient_id = v_uid for update;
  if not found then raise exception 'bank_cheque_not_found'; end if;
  if v_cheque.status <> 'pending' then raise exception 'bank_cheque_already_settled'; end if;

  perform public.bank_touch(v_uid);
  select * into v_acct from public.bank_accounts where player_id = v_uid;
  update public.players set money = money + v_cheque.net_amount::double precision
  where id = v_uid returning money into v_wallet;
  if v_wallet is null then raise exception 'bank_cheque_recipient_missing'; end if;

  update public.bank_cheques set status = 'cashed', cashed_at = now() where id = v_cheque.id;
  insert into public.bank_transactions(player_id, kind, amount, balance_after, loan_after, credit_after, memo)
  values (v_uid, 'cheque_receive', v_cheque.net_amount, v_acct.balance,
          v_acct.loan_principal + v_acct.loan_interest_accrued, v_acct.credit_score,
          'Cheque #' || v_cheque.id || ' from ' || v_cheque.sender_name ||
          '; ' || v_cheque.tax_amount || ' tax withheld');

  insert into public.economy_cash_ledger
    (player_id, account, amount, direction, category, subcategory, reference, metadata)
  values
    (v_uid, 'clearing', -v_cheque.face_amount, 'transfer', 'cheque_escrow', 'release',
     v_cheque.id::text, '{"accountingOnly":true}'::jsonb),
    (v_uid, 'clearing', v_cheque.tax_amount, 'transfer', 'cheque_escrow', 'fee_reclassification',
     v_cheque.id::text, '{"accountingOnly":true}'::jsonb),
    (v_uid, 'clearing', -v_cheque.tax_amount, 'sink', 'cheque_tax', 'cash',
     v_cheque.id::text, '{"accountingOnly":true}'::jsonb);
  return jsonb_build_object('id', v_cheque.id, 'faceAmount', v_cheque.face_amount,
                            'taxAmount', v_cheque.tax_amount, 'netAmount', v_cheque.net_amount);
end;
$$;

create function public.bank_cancel_cheque(p_cheque_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_cheque public.bank_cheques%rowtype;
  v_wallet double precision;
  v_acct public.bank_accounts%rowtype;
begin
  if v_uid is null then raise exception 'unauthenticated'; end if;
  select * into v_cheque from public.bank_cheques
  where id = p_cheque_id and sender_id = v_uid for update;
  if not found then raise exception 'bank_cheque_not_found'; end if;
  if v_cheque.status <> 'pending' then raise exception 'bank_cheque_already_settled'; end if;

  perform public.bank_touch(v_uid);
  select * into v_acct from public.bank_accounts where player_id = v_uid;
  update public.players set money = money + v_cheque.face_amount::double precision
  where id = v_uid returning money into v_wallet;
  if v_wallet is null then raise exception 'bank_cheque_sender_missing'; end if;

  update public.bank_cheques set status = 'cancelled', cancelled_at = now() where id = v_cheque.id;
  insert into public.economy_cash_ledger
    (player_id, account, amount, direction, category, subcategory, reference, metadata)
  values (v_uid, 'clearing', -v_cheque.face_amount, 'transfer', 'cheque_escrow', 'refund',
          v_cheque.id::text, '{"accountingOnly":true}'::jsonb);
  insert into public.bank_transactions(player_id, kind, amount, balance_after, loan_after, credit_after, memo)
  values (v_uid, 'cheque_refund', v_cheque.face_amount, v_acct.balance,
          v_acct.loan_principal + v_acct.loan_interest_accrued, v_acct.credit_score,
          'Cancelled cheque #' || v_cheque.id || ' to ' || v_cheque.recipient_name);
  return jsonb_build_object('id', v_cheque.id, 'refunded', v_cheque.face_amount);
end;
$$;

revoke all on function public.bank_list_cheques(integer,integer) from public, anon;
revoke all on function public.bank_issue_cheque(text,double precision) from public, anon;
revoke all on function public.bank_cash_cheque(bigint) from public, anon;
revoke all on function public.bank_cancel_cheque(bigint) from public, anon;
grant execute on function public.bank_list_cheques(integer,integer) to authenticated;
grant execute on function public.bank_issue_cheque(text,double precision) to authenticated;
grant execute on function public.bank_cash_cheque(bigint) to authenticated;
grant execute on function public.bank_cancel_cheque(bigint) to authenticated;

commit;
