-- Paid Cosmetic Store + Facets v1.
-- Prepared for project igrddscmrdrrwtvyspbf. Local migration only: deploy manually.
-- This does not touch roll functions, gameplay formulas, cash, or total_rolls.
begin;

-- Cosmetic slots are intentionally extensible. Individual loadout keys are
-- validated against the server-owned definition rather than a four-type enum.
alter table public.cosmetic_definitions drop constraint if exists cosmetic_definitions_slots_check;
alter table public.cosmetic_definitions add constraint cosmetic_definitions_slots_check
  check (cardinality(slots) between 1 and 8 and array_position(slots,'') is null);

create table public.cosmetic_store_collections (
  id text primary key,
  name text not null,
  description text not null default '',
  facet_price integer not null check (facet_price >= 0),
  visual_config jsonb not null default '{}' check (jsonb_typeof(visual_config)='object'),
  featured boolean not null default false,
  enabled boolean not null default true,
  sort_order integer not null default 0
);

create table public.cosmetic_store_items (
  cosmetic_id text primary key references public.cosmetic_definitions(id) on delete cascade,
  cosmetic_type text not null check (cosmetic_type ~ '^[a-z][a-z0-9_]{0,31}$'),
  facet_price integer not null check (facet_price >= 0),
  collection_id text references public.cosmetic_store_collections(id) on delete set null,
  featured boolean not null default false,
  enabled boolean not null default true,
  sort_order integer not null default 0
);
create index cosmetic_store_items_collection_idx on public.cosmetic_store_items(collection_id,sort_order);

create table public.facet_wallets (
  player_id uuid primary key references public.players(id) on delete cascade,
  balance bigint not null default 0,
  updated_at timestamptz not null default now()
);

create table public.facet_ledger (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  delta bigint not null check (delta <> 0),
  balance_after bigint not null,
  entry_type text not null,
  source_ref text not null,
  metadata jsonb not null default '{}' check (jsonb_typeof(metadata)='object'),
  created_at timestamptz not null default now(),
  unique(entry_type,source_ref)
);
create index facet_ledger_player_idx on public.facet_ledger(player_id,created_at desc);

create table public.cosmetic_store_orders (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  request_id uuid not null,
  purchase_kind text not null check (purchase_kind in ('item','collection')),
  purchase_id text not null,
  facet_price integer not null check (facet_price >= 0),
  granted_cosmetic_ids text[] not null default '{}',
  created_at timestamptz not null default now(),
  unique(player_id,request_id)
);
create index cosmetic_store_orders_player_idx on public.cosmetic_store_orders(player_id,created_at desc);

create table public.facet_pack_definitions (
  id text primary key,
  facets integer not null unique check (facets > 0),
  price_cents integer not null check (price_cents > 0),
  currency text not null default 'SGD' check (currency='SGD'),
  provider text not null default 'buy_me_a_coffee' check (provider='buy_me_a_coffee'),
  provider_product_id text unique,
  checkout_url text check (checkout_url is null or checkout_url ~ '^https://'),
  enabled boolean not null default true,
  sort_order integer not null default 0,
  check (facets=price_cents)
);

create table public.facet_claim_codes (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  code text not null unique check (code ~ '^GI-[A-F0-9]{8}-[A-F0-9]{4}$'),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '30 days',
  consumed_at timestamptz,
  consumed_transaction_id text
);
create unique index one_active_facet_claim_code_per_player on public.facet_claim_codes(player_id) where consumed_at is null;

create table public.facet_provider_events (
  id bigint generated always as identity primary key,
  provider text not null,
  provider_event_key text not null,
  event_type text not null,
  transaction_id text,
  player_id uuid references public.players(id) on delete set null,
  status text not null default 'received',
  payload jsonb not null,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(provider,provider_event_key)
);
create index facet_provider_events_transaction_idx on public.facet_provider_events(provider,transaction_id);

alter table public.cosmetic_store_collections enable row level security;
alter table public.cosmetic_store_items enable row level security;
alter table public.facet_wallets enable row level security;
alter table public.facet_ledger enable row level security;
alter table public.cosmetic_store_orders enable row level security;
alter table public.facet_pack_definitions enable row level security;
alter table public.facet_claim_codes enable row level security;
alter table public.facet_provider_events enable row level security;
revoke all on public.cosmetic_store_collections,public.cosmetic_store_items,public.facet_wallets,public.facet_ledger,public.cosmetic_store_orders,public.facet_pack_definitions,public.facet_claim_codes,public.facet_provider_events from public,anon,authenticated;
grant select on public.cosmetic_store_collections,public.cosmetic_store_items,public.facet_pack_definitions to authenticated;
grant select on public.facet_wallets,public.facet_ledger,public.cosmetic_store_orders to authenticated;
grant all on public.cosmetic_store_collections,public.cosmetic_store_items,public.facet_wallets,public.facet_ledger,public.cosmetic_store_orders,public.facet_pack_definitions,public.facet_claim_codes,public.facet_provider_events to service_role;
grant usage,select on all sequences in schema public to service_role;
create policy cosmetic_store_collections_read on public.cosmetic_store_collections for select to authenticated using(enabled);
create policy cosmetic_store_items_read on public.cosmetic_store_items for select to authenticated using(enabled);
create policy facet_packs_read on public.facet_pack_definitions for select to authenticated using(enabled);
create policy own_facet_wallet_read on public.facet_wallets for select to authenticated using((select auth.uid())=player_id);
create policy own_facet_ledger_read on public.facet_ledger for select to authenticated using((select auth.uid())=player_id);
create policy own_cosmetic_orders_read on public.cosmetic_store_orders for select to authenticated using((select auth.uid())=player_id);
create policy facet_claim_codes_service on public.facet_claim_codes for all to service_role using(true) with check(true);
create policy facet_provider_events_service on public.facet_provider_events for all to service_role using(true) with check(true);

insert into public.cosmetic_store_collections(id,name,description,facet_price,visual_config,featured,sort_order) values
 ('glitched','Glitched','Restrained signal corruption, RGB displacement and fractured interface details.',600,'{"style":"glitched","icon":"⌁"}',true,10),
 ('celestial','Celestial','A clean midnight starfield with constellations and luminous edges.',600,'{"style":"celestial","icon":"✦"}',true,20),
 ('overgrown','Overgrown','An abandoned mine reclaimed by moss, stone and quiet vines.',600,'{"style":"overgrown","icon":"❧"}',true,30);

insert into public.cosmetic_definitions(id,name,slots,description,rarity,visual_config,source) values
 ('glitched-title','[GLITCHED]',array['title'],'Restrained RGB displacement title.','Epic','{"style":"glitched","icon":"⌁"}','store'),
 ('glitched-background','Glitched Profile Background',array['background'],'Subtle corrupted profile surface.','Epic','{"style":"glitched","icon":"⌁"}','store'),
 ('glitched-roll-card','Glitched Roll Card',array['roll_card'],'Subtle corrupted roll interface.','Epic','{"style":"glitched","icon":"⌁"}','store'),
 ('glitched-leaderboard-skin','Glitched Leaderboard Skin',array['leaderboard_skin'],'Subtle corrupted leaderboard interface.','Epic','{"style":"glitched","icon":"⌁"}','store'),
 ('celestial-title','[CELESTIAL]',array['title'],'Luminous constellation title.','Epic','{"style":"celestial","icon":"✦"}','store'),
 ('celestial-background','Celestial Profile Background',array['background'],'Dark starfield profile surface.','Epic','{"style":"celestial","icon":"✦"}','store'),
 ('celestial-roll-card','Celestial Roll Card',array['roll_card'],'Starfield roll interface.','Epic','{"style":"celestial","icon":"✦"}','store'),
 ('celestial-leaderboard-skin','Celestial Leaderboard Skin',array['leaderboard_skin'],'Constellation leaderboard interface.','Epic','{"style":"celestial","icon":"✦"}','store'),
 ('overgrown-title','[OVERGROWN]',array['title'],'A title reclaimed by the mine.','Epic','{"style":"overgrown","icon":"❧"}','store'),
 ('overgrown-background','Overgrown Profile Background',array['background'],'Moss, stone and vines across the profile.','Epic','{"style":"overgrown","icon":"❧"}','store'),
 ('overgrown-roll-card','Overgrown Roll Card',array['roll_card'],'Reclaimed mine roll interface.','Epic','{"style":"overgrown","icon":"❧"}','store'),
 ('overgrown-leaderboard-skin','Overgrown Leaderboard Skin',array['leaderboard_skin'],'Reclaimed mine leaderboard interface.','Epic','{"style":"overgrown","icon":"❧"}','store'),
 ('gambler-title','[GAMBLER]',array['title'],'For players who know the next roll is the one.','Rare','{"style":"gambler","icon":"♠"}','store'),
 ('quit-99-title','[99% QUIT]',array['title'],'A stubborn reminder to keep digging.','Rare','{"style":"quit99","icon":"↻"}','store'),
 ('retro-desktop-roll-card','Retro Desktop',array['roll_card'],'Original early-desktop window treatment. Adapts to light and dark themes. Concept credit: Flame.','Epic','{"style":"retro-desktop","icon":"▣","credit":"Flame"}','store');

insert into public.cosmetic_store_items(cosmetic_id,cosmetic_type,facet_price,collection_id,featured,sort_order) values
 ('glitched-title','title',100,'glitched',false,10),('glitched-background','background',250,'glitched',false,20),('glitched-roll-card','roll_card',250,'glitched',true,30),('glitched-leaderboard-skin','leaderboard_skin',200,'glitched',false,40),
 ('celestial-title','title',100,'celestial',false,50),('celestial-background','background',250,'celestial',false,60),('celestial-roll-card','roll_card',250,'celestial',true,70),('celestial-leaderboard-skin','leaderboard_skin',200,'celestial',false,80),
 ('overgrown-title','title',100,'overgrown',false,90),('overgrown-background','background',250,'overgrown',false,100),('overgrown-roll-card','roll_card',250,'overgrown',true,110),('overgrown-leaderboard-skin','leaderboard_skin',200,'overgrown',false,120),
 ('gambler-title','title',100,null,false,130),('quit-99-title','title',100,null,false,140),('retro-desktop-roll-card','roll_card',250,null,true,150);

insert into public.facet_pack_definitions(id,facets,price_cents,sort_order) values
 ('facets-100',100,100,10),('facets-250',250,250,20),('facets-500',500,500,30),('facets-1000',1000,1000,40),('facets-2500',2500,2500,50);

-- Resolve arbitrary future single-value slots from server-owned definitions.
create or replace function cosmetics_private.resolved_loadout(p_player uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare eq jsonb; result jsonb:='{}'; slot text; value jsonb; items jsonb;
begin
 select equipment into eq from public.player_cosmetic_loadouts where player_id=p_player;
 if eq is null then
  select jsonb_build_object('trophies',coalesce(jsonb_agg(cosmetic_id),'[]')) into eq from (
   select o.cosmetic_id from public.player_cosmetics o join public.cosmetic_definitions d on d.id=o.cosmetic_id
   where o.player_id=p_player and d.enabled and 'trophy'=any(d.slots) order by o.earned_at desc,o.cosmetic_id limit 5
  ) t;
 end if;
 for slot,value in select * from jsonb_each(coalesce(eq,'{}')) loop
  if slot not in ('badges','trophies','showcase_labels') and jsonb_typeof(value)='string' then
   result:=result||jsonb_build_object(slot,cosmetics_private.item(p_player,value#>>'{}',slot));
  end if;
 end loop;
 foreach slot in array array['title','frame','background','decor','roll_card','leaderboard_skin'] loop
  if not result ? slot then result:=result||jsonb_build_object(slot,null); end if;
 end loop;
 foreach slot in array array['badges','trophies'] loop
  select coalesce(jsonb_agg(item order by ord) filter(where item is not null),'[]') into items from (
   select cosmetics_private.item(p_player,id,case when slot='badges' then 'badge' else null end) item,ord
   from jsonb_array_elements_text(coalesce(eq->slot,'[]')) with ordinality x(id,ord)
   where ord<=case when slot='badges' then 3 else 5 end
  ) t;
  result:=result||jsonb_build_object(slot,items);
 end loop;
 return result||jsonb_build_object('showcase_labels',coalesce(eq->'showcase_labels','[]'));
end $$;
revoke all on function cosmetics_private.resolved_loadout(uuid) from public,anon,authenticated;

create or replace function public.set_my_cosmetic_loadout(p_equipment jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); k text; v jsonb; cid text; ids text[]; allowed_slot text;
begin
 if uid is null then raise exception 'Sign in to customize your profile.' using errcode='42501'; end if;
 if p_equipment is null or jsonb_typeof(p_equipment)<>'object' or octet_length(p_equipment::text)>8192 then raise exception 'Invalid cosmetic equipment.'; end if;
 perform 1 from public.players where id=uid for update;
 if not found then raise exception 'Player not found.'; end if;
 for k,v in select * from jsonb_each(p_equipment) loop
  if k in ('badges','trophies','showcase_labels') then
   if jsonb_typeof(v)<>'array' or jsonb_array_length(v)>(case when k='trophies' then 5 else 3 end) then raise exception 'Invalid cosmetic selection.'; end if;
   if exists(select 1 from jsonb_array_elements(v) x where jsonb_typeof(x)<>'string') then raise exception 'Invalid cosmetic selection.'; end if;
   select coalesce(array_agg(x),'{}') into ids from jsonb_array_elements_text(v) x;
   if k='showcase_labels' then
    if exists(select 1 from unnest(ids) x where length(x)>32 or x ~ '[[:cntrl:]]') then raise exception 'Showcase labels must be 32 characters or fewer.'; end if;
    continue;
   end if;
   if cardinality(ids)<>(select count(distinct x) from unnest(ids) x) then raise exception 'Select each collectible only once per section.'; end if;
   allowed_slot:=case when k='badges' then 'badge' else null end;
  else
   if k !~ '^[a-z][a-z0-9_]{0,31}$' then raise exception 'Unknown cosmetic slot.'; end if;
   if v='null'::jsonb then continue; end if;
   if jsonb_typeof(v)<>'string' then raise exception 'Invalid cosmetic selection.'; end if;
   ids:=array[v#>>'{}']; allowed_slot:=k;
  end if;
  foreach cid in array ids loop
   if cosmetics_private.item(uid,cid,allowed_slot) is null then raise exception 'You do not own an enabled cosmetic for this slot.' using errcode='42501'; end if;
  end loop;
 end loop;
 insert into public.player_cosmetic_loadouts(player_id,equipment) values(uid,p_equipment)
 on conflict(player_id) do update set equipment=excluded.equipment,updated_at=now();
 return cosmetics_private.resolved_loadout(uid);
end $$;
revoke all on function public.set_my_cosmetic_loadout(jsonb) from public,anon,authenticated;
grant execute on function public.set_my_cosmetic_loadout(jsonb) to authenticated;

create or replace function public.get_cosmetic_store() returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); result jsonb;
begin
 if uid is null then raise exception 'Sign in to use the Store.' using errcode='42501'; end if;
 insert into public.facet_wallets(player_id) values(uid) on conflict do nothing;
 select jsonb_build_object(
  'balance',(select balance from public.facet_wallets where player_id=uid),
  'owned',coalesce((select jsonb_agg(cosmetics_private.item(uid,o.cosmetic_id) order by o.earned_at desc) from public.player_cosmetics o join public.cosmetic_definitions d on d.id=o.cosmetic_id where o.player_id=uid and d.enabled),'[]'),
  'equipment',coalesce((select equipment from public.player_cosmetic_loadouts where player_id=uid),'{}'),
  'resolved',cosmetics_private.resolved_loadout(uid),
  'packs',coalesce((select jsonb_agg(jsonb_build_object('id',id,'facets',facets,'cents',price_cents,'checkout_url',checkout_url) order by sort_order) from public.facet_pack_definitions where enabled),'[]')
 ) into result;
 return result;
end $$;
revoke all on function public.get_cosmetic_store() from public,anon,authenticated;
grant execute on function public.get_cosmetic_store() to authenticated;

create or replace function public.purchase_cosmetic_store_item(p_kind text,p_item_id text,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); price integer; ids text[]; existing public.cosmetic_store_orders%rowtype; new_balance bigint;
begin
 if uid is null then raise exception 'Sign in to use the Store.' using errcode='42501'; end if;
 if p_request_id is null or p_kind not in ('item','collection') then raise exception 'Invalid purchase request.'; end if;
 perform 1 from public.players where id=uid for update;
 select * into existing from public.cosmetic_store_orders where player_id=uid and request_id=p_request_id;
 if found then return public.get_cosmetic_store()||jsonb_build_object('order_id',existing.id,'duplicate',true,'balance_after',(select balance from public.facet_wallets where player_id=uid)); end if;
 insert into public.facet_wallets(player_id) values(uid) on conflict do nothing;
 perform 1 from public.facet_wallets where player_id=uid for update;
 if p_kind='item' then
  select i.facet_price,array[i.cosmetic_id] into price,ids from public.cosmetic_store_items i join public.cosmetic_definitions d on d.id=i.cosmetic_id where i.cosmetic_id=p_item_id and i.enabled and d.enabled;
  if price is null then raise exception 'Cosmetic not found.'; end if;
  if exists(select 1 from public.player_cosmetics where player_id=uid and cosmetic_id=p_item_id) then raise exception 'You already own this cosmetic.' using errcode='23505'; end if;
 else
  if not exists(select 1 from public.cosmetic_store_collections where id=p_item_id and enabled) then raise exception 'Collection not found.'; end if;
  select coalesce(array_agg(i.cosmetic_id order by i.sort_order),'{}'),ceil(coalesce(sum(i.facet_price),0)*0.75)::integer into ids,price
  from public.cosmetic_store_items i join public.cosmetic_definitions d on d.id=i.cosmetic_id
  where i.collection_id=p_item_id and i.enabled and d.enabled and not exists(select 1 from public.player_cosmetics o where o.player_id=uid and o.cosmetic_id=i.cosmetic_id);
  if cardinality(ids)=0 then raise exception 'You already own this collection.' using errcode='23505'; end if;
 end if;
 update public.facet_wallets set balance=balance-price,updated_at=now() where player_id=uid and balance>=price returning balance into new_balance;
 if new_balance is null then raise exception 'Not enough Facets.' using errcode='22003'; end if;
 insert into public.player_cosmetics(player_id,cosmetic_id,source,source_key) select uid,x,'store',p_kind||':'||p_item_id from unnest(ids) x on conflict do nothing;
 insert into public.cosmetic_store_orders(player_id,request_id,purchase_kind,purchase_id,facet_price,granted_cosmetic_ids) values(uid,p_request_id,p_kind,p_item_id,price,ids) returning id into existing.id;
 insert into public.facet_ledger(player_id,delta,balance_after,entry_type,source_ref,metadata) values(uid,-price,new_balance,'cosmetic_purchase',existing.id::text,jsonb_build_object('kind',p_kind,'id',p_item_id,'cosmetics',ids));
 return public.get_cosmetic_store()||jsonb_build_object('order_id',existing.id,'duplicate',false,'balance_after',new_balance,'price',price);
end $$;
revoke all on function public.purchase_cosmetic_store_item(text,text,uuid) from public,anon,authenticated;
grant execute on function public.purchase_cosmetic_store_item(text,text,uuid) to authenticated;

create or replace function public.create_facet_claim_code() returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); code text;
begin
 if uid is null then raise exception 'Sign in to create a claim code.' using errcode='42501'; end if;
 code:='GI-'||upper(substr(encode(extensions.gen_random_bytes(8),'hex'),1,8))||'-'||upper(substr(encode(extensions.gen_random_bytes(4),'hex'),1,4));
 update public.facet_claim_codes set consumed_at=now() where player_id=uid and consumed_at is null;
 insert into public.facet_claim_codes(player_id,code) values(uid,code);
 return jsonb_build_object('code',code,'expires_at',now()+interval '30 days');
end $$;
revoke all on function public.create_facet_claim_code() from public,anon,authenticated;
grant execute on function public.create_facet_claim_code() to authenticated;

-- Called only by the verified webhook with the service role. Purchase and
-- refund events are atomic, transaction-idempotent and permanently audited.
create or replace function public.process_bmc_facet_event(p_event jsonb,p_claim_id uuid default null,p_player_id uuid default null) returns jsonb language plpgsql security invoker set search_path='' as $$
declare kind text:=p_event->>'type'; event_key text:=(p_event->>'type')||':'||(p_event->>'event_id')||':'||coalesce(p_event->>'live_mode',''); event_data jsonb:=p_event->'data'; tx text; extra jsonb; target_player uuid:=p_player_id; total_facets integer:=0; expected_cents integer:=0; qty integer; pack record; current_balance bigint; original record; inserted_id bigint;
begin
 if kind not in ('extra_purchase.created','extra_purchase.refunded') then return jsonb_build_object('ignored',true,'reason','unsupported_event'); end if;
 tx:=event_data->>'transaction_id';
 if tx is null or tx='' then raise exception 'Missing transaction ID.'; end if;
 insert into public.facet_provider_events(provider,provider_event_key,event_type,transaction_id,status,payload) values('buy_me_a_coffee',event_key,kind,tx,'received',p_event) on conflict do nothing returning id into inserted_id;
 if inserted_id is null then return jsonb_build_object('duplicate',true); end if;
 if coalesce((p_event->>'live_mode')::boolean,false)=false then update public.facet_provider_events set status='test_ignored',processed_at=now() where id=inserted_id; return jsonb_build_object('ignored',true,'reason','test_event'); end if;
 if kind='extra_purchase.created' then
  if event_data->>'currency'<>'SGD' or event_data->>'status'<>'succeeded' or coalesce(event_data->>'refunded','false')='true' then raise exception 'Payment is not a completed SGD purchase.'; end if;
  if exists(select 1 from public.facet_ledger where entry_type='bmc_purchase' and source_ref=tx) then update public.facet_provider_events set status='duplicate_transaction',processed_at=now() where id=inserted_id; return jsonb_build_object('duplicate',true); end if;
  if p_claim_id is null or target_player is null then raise exception 'A valid Gem Incremental claim code is required.'; end if;
  for extra in select value from jsonb_array_elements(coalesce(event_data->'extras','[]')) loop
   qty:=greatest(1,least(100,coalesce((extra->>'quantity')::integer,1)));
   select * into pack from public.facet_pack_definitions where provider='buy_me_a_coffee' and provider_product_id=extra->>'id' and enabled;
   if not found then raise exception 'Unknown Buy Me a Coffee product ID.'; end if;
   total_facets:=total_facets+pack.facets*qty; expected_cents:=expected_cents+pack.price_cents*qty;
  end loop;
  if expected_cents<>round((event_data->>'amount')::numeric*100)::integer then raise exception 'Pack price does not match the configured SGD amount.'; end if;
  insert into public.facet_wallets(player_id) values(target_player) on conflict do nothing;
  update public.facet_wallets set balance=balance+total_facets,updated_at=now() where player_id=target_player returning balance into current_balance;
  insert into public.facet_ledger(player_id,delta,balance_after,entry_type,source_ref,metadata) values(target_player,total_facets,current_balance,'bmc_purchase',tx,jsonb_build_object('event_id',p_event->>'event_id','amount_cents',expected_cents));
  update public.facet_provider_events set status='processed',player_id=target_player,processed_at=now() where id=inserted_id;
  return jsonb_build_object('credited',total_facets,'balance',current_balance);
 else
  select player_id,delta into original from public.facet_ledger where entry_type='bmc_purchase' and source_ref=tx;
  if not found then raise exception 'Original Facet purchase was not found.'; end if;
  if exists(select 1 from public.facet_ledger where entry_type='bmc_refund' and source_ref=tx) then update public.facet_provider_events set status='duplicate_refund',player_id=original.player_id,processed_at=now() where id=inserted_id; return jsonb_build_object('duplicate',true); end if;
  update public.facet_wallets set balance=balance-original.delta,updated_at=now() where player_id=original.player_id returning balance into current_balance;
  insert into public.facet_ledger(player_id,delta,balance_after,entry_type,source_ref,metadata) values(original.player_id,-original.delta,current_balance,'bmc_refund',tx,jsonb_build_object('event_id',p_event->>'event_id'));
  update public.facet_provider_events set status='refunded',player_id=original.player_id,processed_at=now() where id=inserted_id;
  return jsonb_build_object('debited',original.delta,'balance',current_balance);
 end if;
exception when others then
 -- The transaction rolls back, causing BMC to retry instead of acknowledging a partial grant.
 raise;
end $$;
revoke all on function public.process_bmc_facet_event(jsonb,uuid,uuid) from public,anon,authenticated;
grant execute on function public.process_bmc_facet_event(jsonb,uuid,uuid) to service_role;

create or replace function public.get_public_player_titles(p_user_ids uuid[]) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_object_agg(p.id::text,jsonb_build_object(
 'title',coalesce(nullif(t.title,''),nullif(p.display_title,''),''),
 'title_color',coalesce(nullif(t.color,''),nullif(p.display_title_color,''),'#ffd166'),
 'collectible_title',cosmetics_private.item(p.id,l.equipment->>'title','title'),
 'leaderboard_skin',cosmetics_private.item(p.id,l.equipment->>'leaderboard_skin','leaderboard_skin'))),'{}')
 from public.players p left join public.player_titles t on t.player_id=p.id left join public.player_cosmetic_loadouts l on l.player_id=p.id
 where p.id=any(coalesce(p_user_ids,'{}'::uuid[]));
$$;
revoke all on function public.get_public_player_titles(uuid[]) from public;
grant execute on function public.get_public_player_titles(uuid[]) to anon,authenticated;

commit;
