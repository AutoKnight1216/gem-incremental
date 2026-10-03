-- Replace fixed-price market listings with server-authoritative auctions.
-- Existing fixed-price listings are returned and open buy orders are refunded
-- so neither legacy path can bypass the new auction rules.

-- The two Money Up potions are being introduced in this weekly update. Their
-- reference values follow their configured crafting costs so every currently
-- defined consumable remains tradeable.
create or replace function public._market_consumable_shop_value(p_consumable_id text)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select case p_consumable_id
    when 'lucky-potion-1' then 100
    when 'lucky-potion-2' then 40000
    when 'lucky-potion-3' then 150000
    when 'lucky-potion-4' then 500000
    when 'speed-potion-1' then 100
    when 'speed-potion-2' then 40000
    when 'speed-potion-3' then 150000
    when 'speed-potion-4' then 500000
    when 'fortune-potion-1' then 100
    when 'fortune-potion-2' then 40000
    when 'fortune-potion-3' then 150000
    when 'fortune-potion-4' then 500000
    when 'mass-potion-1' then 100
    when 'mass-potion-2' then 40000
    when 'mass-potion-3' then 150000
    when 'mass-potion-4' then 500000
    when 'legendary-potion' then 3000000
    when 'mythic-potion' then 15000000
    when 'relic-potion' then 50000
    when 'seismic-potion' then 1750000
    when 'unstable-core' then 10000000
    when 'deepcore-catalyst' then 300000
    when 'pressurized-catalyst' then 2500000
    when 'deepcore-crate' then 3000000
    when 'diver' then 1000000
    when 'tidal-rush' then 1250000
    when 'pressure' then 12500000
    when 'offering' then 3000000
    when 'treasure-tonic' then 2500000
    when 'supply-crate' then 4000000
    when 'abyssal-potion' then 60000000
    when 'pet-luck-treat' then 500000
    when 'enchanted-pet-toy' then 2000000
    when 'celestial-pet-charm' then 7500000
    when 'mythic-pet-whistle' then 20000000
    when 'plastic-bag' then 0.10
    when 'money-up-potion' then 25000
    when 'money-up-potion-2' then 100000
    else null
  end::numeric;
$function$;

revoke all on function public._market_consumable_shop_value(text) from public, anon, authenticated;

alter table public.auctions
  add column if not exists lot_reference_value numeric,
  add column if not exists original_ends_at timestamptz,
  add column if not exists anti_snipe_extension_seconds integer not null default 0,
  add column if not exists listing_fee_rate numeric,
  add column if not exists listing_fee_amount numeric;

alter table public.auctions
  alter column start_price type numeric using start_price::numeric,
  alter column current_bid type numeric using current_bid::numeric;

alter table public.auction_bids
  alter column amount type numeric using amount::numeric;

create index if not exists auction_bids_bidder_cooldown_idx
  on public.auction_bids (auction_id, bidder_id, created_at desc);

-- Return every fixed-price listing instead of silently changing the seller's
-- terms. This also refunds any legacy bid escrow before the lot is returned.
do $migration$
declare
  v_a public.auctions%rowtype;
begin
  for v_a in
    select * from public.auctions where status = 'active' for update
  loop
    if v_a.current_bidder_id is not null and v_a.current_bid is not null then
      update public.players
      set money = money + v_a.current_bid
      where id = v_a.current_bidder_id;
    end if;

    if v_a.lot is not null then
      perform public._auction_restore_lot(v_a.seller_id, v_a.lot);
    else
      perform public._auction_restore_gem(v_a.seller_id, v_a.gem);
    end if;

    insert into public.auction_transactions
      (auction_id, player_id, event_type, details)
    values
      (v_a.id, v_a.seller_id, 'lot_returned',
       jsonb_build_object('reason', 'market_redesign', 'item_count', v_a.item_count));

    update public.auctions
    set status = 'returned', settled_at = now()
    where id = v_a.id;
  end loop;
end;
$migration$;

-- Refund only the escrowed offer. The already-paid legacy order fee remains
-- non-refundable, matching the terms under which those orders were posted.
do $migration$
declare
  v_o public.gem_orders%rowtype;
begin
  for v_o in
    select * from public.gem_orders where status = 'open' for update
  loop
    update public.players set money = money + v_o.price where id = v_o.buyer_id;
    update public.gem_orders set status = 'cancelled' where id = v_o.id;
  end loop;
end;
$migration$;

create or replace function public._auction_listing_fee_rate(p_duration_hours integer)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select case p_duration_hours
    when 6 then 0.005
    when 12 then 0.0075
    when 24 then 0.01
    when 48 then 0.015
    when 72 then 0.02
    else null
  end::numeric;
$function$;

create or replace function public._auction_seller_tax(p_price numeric, p_reference_value numeric)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select case
    when p_price is null or p_reference_value is null or p_price < 0 or p_reference_value <= 0 then null
    else
      least(p_price, 2 * p_reference_value) * 0.02
      + greatest(least(p_price, 5 * p_reference_value) - 2 * p_reference_value, 0) * 0.03
      + greatest(least(p_price, 10 * p_reference_value) - 5 * p_reference_value, 0) * 0.04
      + greatest(least(p_price, 25 * p_reference_value) - 10 * p_reference_value, 0) * 0.05
      + greatest(least(p_price, 50 * p_reference_value) - 25 * p_reference_value, 0) * 0.075
      + greatest(p_price - 50 * p_reference_value, 0) * 0.10
  end;
$function$;

revoke all on function public._auction_listing_fee_rate(integer) from public, anon, authenticated;
revoke all on function public._auction_seller_tax(numeric, numeric) from public, anon, authenticated;

create or replace function public.create_auction_lot(
  p_items jsonb,
  p_start_price double precision,
  p_duration_hours integer
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_hours integer := p_duration_hours;
  v_active integer;
  v_item jsonb;
  v_gem public.inventory_gems%rowtype;
  v_lot jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_gemcount integer := 0;
  v_maxrarity integer := 0;
  v_headline text;
  v_username text;
  v_auction_id bigint;
  v_cid text;
  v_qty integer;
  v_consumable_value numeric;
  v_reference_value numeric := 0;
  v_start_price numeric := p_start_price::numeric;
  v_listing_fee_rate numeric;
  v_listing_fee numeric;
  v_money numeric;
  v_ends_at timestamptz;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_start_price is null or p_start_price::text in ('NaN', 'Infinity', '-Infinity') then
    raise exception 'invalid_price';
  end if;
  if v_hours not in (6, 12, 24, 48, 72) then raise exception 'invalid_duration'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'empty_lot';
  end if;
  if jsonb_array_length(p_items) > 25 then raise exception 'lot_too_large'; end if;

  -- This seller-row lock serializes listing-limit checks and fee deductions
  -- across simultaneous create requests.
  select money::numeric, username into v_money, v_username
  from public.players where id = v_uid for update;
  if not found then raise exception 'seller_player_missing'; end if;

  select count(*) into v_active
  from public.auctions
  where seller_id = v_uid and status = 'active';
  if v_active >= 3 then raise exception 'too_many_listings'; end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if v_item->>'type' = 'potion' then
      v_cid := nullif(btrim(v_item->>'consumable_id'), '');
      begin
        v_qty := (v_item->>'quantity')::integer;
      exception when others then
        raise exception 'invalid_quantity';
      end;
      if v_cid is null or v_qty is null or v_qty <= 0 then raise exception 'invalid_quantity'; end if;

      v_consumable_value := public._market_consumable_shop_value(v_cid);
      if v_consumable_value is null then
        raise exception 'consumable_not_market_priced:%', coalesce(v_cid, '');
      end if;

      update public.player_consumables
      set quantity = quantity - v_qty, updated_at = now()
      where player_id = v_uid and consumable_id = v_cid and quantity >= v_qty;
      if not found then raise exception 'potion_unavailable'; end if;

      v_reference_value := v_reference_value + v_consumable_value * v_qty;
      v_lot := v_lot || jsonb_build_object(
        'type', 'potion', 'consumable_id', v_cid, 'quantity', v_qty
      );
      v_count := v_count + v_qty;
    elsif v_item->>'type' = 'gem' then
      delete from public.inventory_gems
      where id = (v_item->>'id')::bigint and player_id = v_uid and locked = false
      returning * into v_gem;
      if not found then raise exception 'gem_unavailable'; end if;
      if v_gem.gem_name in ('Enchant Relic', 'Ancient Relic') then raise exception 'not_auctionable'; end if;

      v_reference_value := v_reference_value + greatest(0::numeric, coalesce(v_gem.value, 0)::numeric);
      v_lot := v_lot || (
        to_jsonb(v_gem) - 'id' - 'player_id' - 'created_at' || jsonb_build_object('type', 'gem')
      );
      v_count := v_count + 1;
      v_gemcount := v_gemcount + 1;
      if coalesce(v_gem.rarity, 0) > v_maxrarity then v_maxrarity := v_gem.rarity; end if;
      if v_headline is null then v_headline := v_gem.gem_name; end if;
    else
      raise exception 'not_auctionable';
    end if;
  end loop;

  if v_reference_value <= 0 then raise exception 'invalid_reference_value'; end if;
  if v_start_price < v_reference_value * 0.5 then
    raise exception 'start_bid_below_minimum:%', v_reference_value * 0.5;
  end if;
  if v_start_price > v_reference_value * 10 then
    raise exception 'start_bid_above_maximum:%', v_reference_value * 10;
  end if;

  v_listing_fee_rate := public._auction_listing_fee_rate(v_hours);
  v_listing_fee := v_reference_value * v_listing_fee_rate;

  if v_money < v_listing_fee then raise exception 'not_enough_money_for_listing_fee'; end if;
  update public.players set money = money - v_listing_fee::double precision where id = v_uid;

  if not (v_count = 1 and v_gemcount = 1) then v_headline := 'Bundle'; end if;
  v_ends_at := now() + make_interval(hours => v_hours);

  insert into public.auctions (
    seller_id, seller_name, gem, lot, item_count, gem_name, rarity,
    start_price, current_bid, current_bidder_id, current_bidder_name, bid_count,
    ends_at, original_ends_at, anti_snipe_extension_seconds,
    lot_reference_value, listing_fee_rate, listing_fee_amount
  ) values (
    v_uid, v_username, null, v_lot, v_count, v_headline, v_maxrarity,
    v_start_price, null, null, null, 0,
    v_ends_at, v_ends_at, 0,
    v_reference_value, v_listing_fee_rate, v_listing_fee
  ) returning id into v_auction_id;

  insert into public.market_fee_transactions
    (market_type, reference_id, player_id, amount, rate)
  values
    ('listing', v_auction_id, v_uid, v_listing_fee, v_listing_fee_rate);

  return v_auction_id;
end;
$function$;

create or replace function public.place_bid(p_auction_id bigint, p_amount double precision)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_a public.auctions%rowtype;
  v_amount numeric := p_amount::numeric;
  v_money numeric;
  v_username text;
  v_minimum numeric;
  v_maximum numeric;
  v_last_bid_at timestamptz;
  v_extension_seconds integer;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_amount is null or p_amount::text in ('NaN', 'Infinity', '-Infinity') then raise exception 'invalid_bid'; end if;

  select * into v_a from public.auctions where id = p_auction_id for update;
  if not found then raise exception 'auction_not_found'; end if;
  if v_a.status <> 'active' or v_a.ends_at <= now() then raise exception 'auction_closed'; end if;
  if v_a.lot_reference_value is null or v_a.lot_reference_value <= 0 then raise exception 'auction_reference_missing'; end if;
  if v_a.seller_id = v_uid then raise exception 'cannot_bid_own'; end if;
  if v_a.current_bidder_id = v_uid then raise exception 'consecutive_bid_not_allowed'; end if;

  if v_a.current_bid is null then
    v_minimum := v_a.start_price::numeric;
    v_maximum := v_a.start_price::numeric;
  else
    v_minimum := v_a.current_bid::numeric + v_a.lot_reference_value * 0.1;
    v_maximum := v_a.current_bid::numeric + v_a.lot_reference_value * 25;
  end if;
  if v_amount < v_minimum then raise exception 'bid_too_low:%', v_minimum; end if;
  if v_amount > v_maximum then raise exception 'bid_too_high:%', v_maximum; end if;

  select max(created_at) into v_last_bid_at
  from public.auction_bids
  where auction_id = p_auction_id and bidder_id = v_uid;
  if v_last_bid_at is not null and v_last_bid_at + interval '1 hour' > now() then
    raise exception 'bid_cooldown:%', v_last_bid_at + interval '1 hour';
  end if;

  -- Lock both balance rows in UUID order to avoid cross-auction deadlocks.
  perform 1 from public.players
  where id = v_uid or id = v_a.current_bidder_id
  order by id
  for update;

  select money::numeric, username into v_money, v_username
  from public.players where id = v_uid;
  if not found then raise exception 'bidder_player_missing'; end if;
  if v_money < v_amount then raise exception 'not_enough_money'; end if;

  if v_a.current_bidder_id is not null then
    update public.players
    set money = money + v_a.current_bid
    where id = v_a.current_bidder_id;
    if not found then raise exception 'previous_bidder_player_missing'; end if;

    insert into public.auction_transactions
      (auction_id, player_id, event_type, amount)
    values
      (v_a.id, v_a.current_bidder_id, 'bid_refunded', v_a.current_bid);
  end if;

  update public.players set money = money - v_amount::double precision where id = v_uid;

  v_extension_seconds := v_a.anti_snipe_extension_seconds;
  if v_a.ends_at <= now() + interval '2 minutes' then
    v_extension_seconds := least(600, v_extension_seconds + 120);
  end if;

  update public.auctions
  set current_bid = v_amount,
      current_bidder_id = v_uid,
      current_bidder_name = v_username,
      bid_count = bid_count + 1,
      anti_snipe_extension_seconds = v_extension_seconds,
      ends_at = original_ends_at + make_interval(secs => v_extension_seconds)
  where id = p_auction_id;

  insert into public.auction_bids (auction_id, bidder_id, bidder_name, amount)
  values (p_auction_id, v_uid, v_username, v_amount);

  insert into public.auction_transactions
    (auction_id, player_id, event_type, amount)
  values
    (p_auction_id, v_uid, 'bid_escrowed', v_amount);

  return jsonb_build_object(
    'auctionId', p_auction_id,
    'amount', v_amount,
    'money', v_money - v_amount,
    'endsAt', v_a.original_ends_at + make_interval(secs => v_extension_seconds),
    'antiSnipeExtensionSeconds', v_extension_seconds,
    'minimumNextBid', v_amount + v_a.lot_reference_value * 0.1,
    'maximumNextBid', v_amount + v_a.lot_reference_value * 25
  );
end;
$function$;

create or replace function public.settle_due_auctions()
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_a public.auctions%rowtype;
  v_count integer := 0;
  v_tax numeric;
  v_proceeds numeric;
begin
  for v_a in
    select * from public.auctions
    where status = 'active' and ends_at <= now()
    for update skip locked
  loop
    if v_a.current_bidder_id is not null then
      v_tax := public._auction_seller_tax(v_a.current_bid::numeric, v_a.lot_reference_value);
      if v_tax is null then raise exception 'auction_reference_missing:%', v_a.id; end if;
      v_proceeds := v_a.current_bid::numeric - v_tax;

      if v_a.lot is not null then
        perform public._auction_restore_lot(v_a.current_bidder_id, v_a.lot);
      else
        perform public._auction_restore_gem(v_a.current_bidder_id, v_a.gem);
      end if;

      update public.players
      set money = money + v_proceeds::double precision
      where id = v_a.seller_id;
      if not found then raise exception 'auction_seller_player_missing:%', v_a.id; end if;

      insert into public.auction_transactions
        (auction_id, player_id, event_type, amount, details)
      values
        (v_a.id, v_a.current_bidder_id, 'lot_delivered', null,
         jsonb_build_object('item_count', v_a.item_count)),
        (v_a.id, v_a.seller_id, 'seller_paid', v_proceeds,
         jsonb_build_object('winning_bid', v_a.current_bid, 'seller_tax', v_tax));

      insert into public.market_fee_transactions
        (market_type, reference_id, player_id, amount, rate)
      values
        ('listing', v_a.id, v_a.seller_id, v_tax, v_tax / v_a.current_bid::numeric);

      update public.auctions
      set status = 'sold', settled_at = now(),
          fee_rate = v_tax / v_a.current_bid::numeric,
          fee_amount = v_tax
      where id = v_a.id;
    else
      if v_a.lot is not null then
        perform public._auction_restore_lot(v_a.seller_id, v_a.lot);
      else
        perform public._auction_restore_gem(v_a.seller_id, v_a.gem);
      end if;

      insert into public.auction_transactions
        (auction_id, player_id, event_type, details)
      values
        (v_a.id, v_a.seller_id, 'lot_returned',
         jsonb_build_object('reason', 'expired', 'item_count', v_a.item_count));

      update public.auctions set status = 'returned', settled_at = now() where id = v_a.id;
    end if;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$function$;

create or replace function public.cancel_auction(p_auction_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_a public.auctions%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select * into v_a from public.auctions where id = p_auction_id for update;
  if not found then raise exception 'auction_not_found'; end if;
  if v_a.seller_id <> v_uid then raise exception 'not_your_auction'; end if;
  if v_a.status <> 'active' or v_a.ends_at <= now() then raise exception 'auction_closed'; end if;
  if v_a.bid_count > 0 or v_a.current_bidder_id is not null then raise exception 'has_bids'; end if;

  if v_a.lot is not null then
    perform public._auction_restore_lot(v_uid, v_a.lot);
  else
    perform public._auction_restore_gem(v_uid, v_a.gem);
  end if;

  insert into public.auction_transactions
    (auction_id, player_id, event_type, details)
  values
    (v_a.id, v_uid, 'lot_returned',
     jsonb_build_object('reason', 'cancelled', 'item_count', v_a.item_count));

  update public.auctions set status = 'cancelled', settled_at = now() where id = p_auction_id;
  return jsonb_build_object('cancelled', p_auction_id, 'listingFeeRefunded', false);
end;
$function$;

-- The market UI no longer calls these. Revoke every browser-accessible grant
-- as defense in depth while retaining the legacy schema and data for history.
revoke all on function public.buy_auction(bigint) from public, anon, authenticated;
revoke all on function public.create_auction(bigint, double precision, integer) from public, anon, authenticated;
revoke all on function public.create_gem_order(text, double precision) from public, anon, authenticated;
revoke all on function public.fulfill_gem_order(bigint, bigint) from public, anon, authenticated;
revoke all on function public.cancel_gem_order(bigint) from public, anon, authenticated;
revoke all on function public.expire_stale_gem_orders() from public, anon, authenticated;

revoke all on function public.create_auction_lot(jsonb, double precision, integer) from public, anon;
revoke all on function public.place_bid(bigint, double precision) from public, anon;
revoke all on function public.cancel_auction(bigint) from public, anon;
revoke all on function public.settle_due_auctions() from public, anon;
grant execute on function public.create_auction_lot(jsonb, double precision, integer) to authenticated;
grant execute on function public.place_bid(bigint, double precision) to authenticated;
grant execute on function public.cancel_auction(bigint) to authenticated;
grant execute on function public.settle_due_auctions() to authenticated;
