begin;

-- Durable provenance is required for the recipe's genuine/natural clauses.
-- Existing retained server rolls are backfilled conservatively; generated
-- duplicates are explicitly excluded.
alter table public.inventory_gems
  add column if not exists natural_mutation_ids text[] not null default '{}'::text[],
  add column if not exists effective_rarity numeric,
  add column if not exists genuine_roll boolean not null default false;

-- Auction escrow serializes the entire specimen, but the legacy restore helper
-- enumerates columns. Keep Paradox provenance (and existing event provenance)
-- intact when a specimen is returned or delivered to its buyer.
create or replace function public._auction_restore_gem(p_owner uuid, p_gem jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.inventory_gems (
    player_id, serial_number, gem_name, rarity, base_weight, value_per_gram,
    rolled_weight_multiplier, rolled_weight, final_weight, value, locked,
    roll_number, luck_at_roll, mutation_id, mutation_multiplier,
    mutation_ids, mutation_multipliers, mutation_chance_multiplier,
    museum_locked, source_event_occurrence_id, source_event_key,
    event_properties, value_multiplier_at_roll,
    natural_mutation_ids, effective_rarity, genuine_roll
  )
  select
    p_owner, r.serial_number, r.gem_name, r.rarity, r.base_weight, r.value_per_gram,
    r.rolled_weight_multiplier, r.rolled_weight, r.final_weight, r.value, false,
    r.roll_number, r.luck_at_roll, r.mutation_id, r.mutation_multiplier,
    r.mutation_ids, r.mutation_multipliers,
    coalesce(r.mutation_chance_multiplier, 1),
    false, r.source_event_occurrence_id, r.source_event_key,
    coalesce(r.event_properties, '{}'::jsonb), coalesce(r.value_multiplier_at_roll, 1),
    coalesce(r.natural_mutation_ids, '{}'::text[]), r.effective_rarity,
    coalesce(r.genuine_roll, false)
  from jsonb_populate_record(null::public.inventory_gems, p_gem) r;
end;
$$;
revoke all on function public._auction_restore_gem(uuid,jsonb) from public,anon,authenticated;

update public.inventory_gems
set
  natural_mutation_ids = array(
    select mutation_id from unnest(coalesce(mutation_ids,'{}'::text[])) mutation_id
    where mutation_id not in ('tryhard','shifted','balanced','ascended','supersizer-small','supersizer-big',
      'supersizer-giant','supersizer-massive','supersizer-colossal','supersizer-titanic','supersizer-gargantuan',
      'silly-small','silly-large','happy')
  ),
  effective_rarity = greatest(1,rarity * public.get_mutation_chance_product(coalesce(mutation_ids,'{}'::text[]))),
  genuine_roll = roll_number is not null and coalesce((event_properties->>'duplicate')::boolean,false)=false
where effective_rarity is null or (cardinality(natural_mutation_ids)=0 and cardinality(coalesce(mutation_ids,'{}'::text[]))>0)
   or (not genuine_roll and roll_number is not null);

create schema if not exists paradox_private;
revoke all on schema paradox_private from public,anon,authenticated;

insert into public.game_recipes(id,recipe)
values('paradox-pickaxe',jsonb_build_object(
  'id','paradox-pickaxe','name','Paradox Pickaxe','category','pickaxe','horizontal',false,
  'equipmentOverhaul',true,'consumeMaterials',true,'paradoxWorkspace',true,'moneyCost',4000000000,
  'description','Resolve impossible specimens into a generalist pickaxe that turns contradictions into escalating rolls.',
  'requirements',jsonb_build_array(
    jsonb_build_object('type','equipment','equipmentId','celestial-pickaxe','consume',false),
    jsonb_build_object('id','paradox-workspace','type','paradox-workspace','amount',1,'label','Paradox recipe and Final Trial')
  ),
  'reward',jsonb_build_object('id','paradox-pickaxe','name','Paradox Pickaxe','category','pickaxe','tier',16,
    'bonus',jsonb_build_object('luck',33,'rollSpeed',2.1,'mutationChance',0.5,'weightLuck',4.5,'weightMultiplier',0.7))
)) on conflict(id) do update set recipe=excluded.recipe;

create or replace function paradox_private.empty_materials()
returns jsonb language sql immutable set search_path='' as $$
 select '{"selectedCount":0,"totalMass":0,"legendary":0,"mythic":0,"exotic":0,"exalted":0,"cosmic":0,"transcendent":0,"wm5":0,"wm10":0,"wm30":0,"effective5b":0,"effective25b":0,"effective100b":0,"under001g":0,"over1mg":0,"natural4":0,"quartzUnmutated":0,"seven7s":0,"combinedTrophy":0,"ladder":{"common":false,"uncommon":false,"rare":false,"epic":false,"legendary":false,"mythic":false,"exotic":false,"exalted":false,"cosmic":false,"transcendent":false}}'::jsonb
$$;
revoke all on function paradox_private.empty_materials() from public,anon,authenticated;

create or replace function paradox_private.materials(p_uid uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce((select progress->'_paradoxMaterials' from public.crafting_progress
   where player_id=p_uid and recipe_id='paradox-pickaxe'),paradox_private.empty_materials())
$$;
revoke all on function paradox_private.materials(uuid) from public,anon,authenticated;

create or replace function paradox_private.materials_ready(p jsonb)
returns boolean language sql immutable set search_path='' as $$
 select coalesce((p->>'totalMass')::numeric,0)>=200000000
   and coalesce((p->>'legendary')::numeric,0)>=20000 and coalesce((p->>'mythic')::numeric,0)>=7500
   and coalesce((p->>'exotic')::numeric,0)>=1500 and coalesce((p->>'exalted')::numeric,0)>=750
   and coalesce((p->>'cosmic')::numeric,0)>=100 and coalesce((p->>'transcendent')::numeric,0)>=5
   and coalesce((p->>'wm5')::numeric,0)>=2250 and coalesce((p->>'wm10')::numeric,0)>=75
   and coalesce((p->>'wm30')::numeric,0)>=1
   and coalesce((p->>'effective5b')::numeric,0)>=25 and coalesce((p->>'effective25b')::numeric,0)>=5
   and coalesce((p->>'effective100b')::numeric,0)>=1
   and coalesce((p->>'under001g')::numeric,0)>=3 and coalesce((p->>'over1mg')::numeric,0)>=3
   and coalesce((p->>'natural4')::numeric,0)>=1 and coalesce((p->>'quartzUnmutated')::numeric,0)>=1000
   and coalesce((p->>'seven7s')::numeric,0)>=7 and coalesce((p->>'combinedTrophy')::numeric,0)>=1
   and coalesce((p->'ladder'->>'common')::boolean,false)
   and coalesce((p->'ladder'->>'uncommon')::boolean,false)
   and coalesce((p->'ladder'->>'rare')::boolean,false)
   and coalesce((p->'ladder'->>'epic')::boolean,false)
   and coalesce((p->'ladder'->>'legendary')::boolean,false)
   and coalesce((p->'ladder'->>'mythic')::boolean,false)
   and coalesce((p->'ladder'->>'exotic')::boolean,false)
   and coalesce((p->'ladder'->>'exalted')::boolean,false)
   and coalesce((p->'ladder'->>'cosmic')::boolean,false)
   and coalesce((p->'ladder'->>'transcendent')::boolean,false)
$$;
revoke all on function paradox_private.materials_ready(jsonb) from public,anon,authenticated;

create or replace function paradox_private.has_secret_roll(p_uid uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.rare_roll_chat_events where player_id=p_uid and rarity>=1000000000)
     or exists(select 1 from public.best_roll_history where player_id=p_uid and rarity>=1000000000)
$$;
revoke all on function paradox_private.has_secret_roll(uuid) from public,anon,authenticated;

create or replace function paradox_private.deposit_specimen(p_uid uuid,p_specimen jsonb,p_only_if_useful boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_progress jsonb; material jsonb; ladder jsonb; useful boolean:=false;
 rarity numeric:=coalesce((p_specimen->>'rarity')::numeric,0);
 base_weight numeric:=coalesce((p_specimen->>'base_weight')::numeric,0);
 final_weight numeric:=coalesce((p_specimen->>'final_weight')::numeric,0);
 final_wm numeric:=case when coalesce((p_specimen->>'base_weight')::numeric,0)>0 then
   coalesce((p_specimen->>'final_weight')::numeric,0)/(p_specimen->>'base_weight')::numeric else 0 end;
 effective numeric:=coalesce((p_specimen->>'effective_rarity')::numeric,
   rarity*public.get_mutation_chance_product(array(select jsonb_array_elements_text(coalesce(p_specimen->'mutation_ids','[]'::jsonb)))));
 mutation_ids text[]:=array(select jsonb_array_elements_text(coalesce(p_specimen->'mutation_ids','[]'::jsonb)));
 natural_ids text[]:=array(select jsonb_array_elements_text(coalesce(p_specimen->'natural_mutation_ids','[]'::jsonb)));
 genuine boolean:=coalesce((p_specimen->>'genuine_roll')::boolean,false);
 gem_name text:=p_specimen->>'gem_name';
begin
 if p_uid is null or gem_name is null then raise exception 'invalid_paradox_deposit'; end if;
 if gem_name in ('Enchant Relic','Ancient Relic') then return jsonb_build_object('deposited',false,'preserved',true,'reason','protected_relic'); end if;
 insert into public.crafting_progress(player_id,recipe_id,progress) values(p_uid,'paradox-pickaxe','{}'::jsonb)
 on conflict(player_id,recipe_id) do nothing;
 select cp.progress into v_progress from public.crafting_progress cp where player_id=p_uid and recipe_id='paradox-pickaxe' for update;
 material:=coalesce(v_progress->'_paradoxMaterials',paradox_private.empty_materials());

 useful:=coalesce((material->>'totalMass')::numeric,0)<200000000
  or (rarity>=1000 and rarity<10000 and coalesce((material->>'legendary')::numeric,0)<20000)
  or (rarity>=10000 and rarity<100000 and coalesce((material->>'mythic')::numeric,0)<7500)
  or (rarity>=100000 and rarity<1000000 and coalesce((material->>'exotic')::numeric,0)<1500)
  or (rarity>=1000000 and rarity<10000000 and coalesce((material->>'exalted')::numeric,0)<750)
  or (rarity>=10000000 and rarity<100000000 and coalesce((material->>'cosmic')::numeric,0)<100)
  or (rarity>=100000000 and rarity<1000000000 and coalesce((material->>'transcendent')::numeric,0)<5)
  or (final_wm>=5 and coalesce((material->>'wm5')::numeric,0)<2250)
  or (final_wm>=10 and coalesce((material->>'wm10')::numeric,0)<75)
  or (final_wm>=30 and coalesce((material->>'wm30')::numeric,0)<1)
  or (effective>=5000000000 and coalesce((material->>'effective5b')::numeric,0)<25)
  or (effective>=25000000000 and coalesce((material->>'effective25b')::numeric,0)<5)
  or (effective>=100000000000 and coalesce((material->>'effective100b')::numeric,0)<1)
  or (final_weight<0.01 and coalesce((material->>'under001g')::numeric,0)<3)
  or (final_weight>1000000 and coalesce((material->>'over1mg')::numeric,0)<3)
  or (genuine and cardinality(natural_ids)>=4 and coalesce((material->>'natural4')::numeric,0)<1)
  or (gem_name='Quartz' and cardinality(mutation_ids)=0 and coalesce((material->>'quartzUnmutated')::numeric,0)<1000)
  or (genuine and final_wm>=7 and final_wm<8 and coalesce((material->>'seven7s')::numeric,0)<7)
  or (final_wm>=10 and effective>=25000000000 and coalesce((material->>'combinedTrophy')::numeric,0)<1)
  or (rarity>=1 and rarity<10 and not coalesce((material->'ladder'->>'common')::boolean,false))
  or (rarity>=10 and rarity<50 and not coalesce((material->'ladder'->>'uncommon')::boolean,false))
  or (rarity>=50 and rarity<100 and not coalesce((material->'ladder'->>'rare')::boolean,false))
  or (rarity>=100 and rarity<1000 and not coalesce((material->'ladder'->>'epic')::boolean,false))
  or (rarity>=1000 and rarity<10000 and not coalesce((material->'ladder'->>'legendary')::boolean,false))
  or (rarity>=10000 and rarity<100000 and not coalesce((material->'ladder'->>'mythic')::boolean,false))
  or (rarity>=100000 and rarity<1000000 and not coalesce((material->'ladder'->>'exotic')::boolean,false))
  or (rarity>=1000000 and rarity<10000000 and not coalesce((material->'ladder'->>'exalted')::boolean,false))
  or (rarity>=10000000 and rarity<100000000 and not coalesce((material->'ladder'->>'cosmic')::boolean,false))
  or (rarity>=100000000 and rarity<1000000000 and not coalesce((material->'ladder'->>'transcendent')::boolean,false));
 if p_only_if_useful and not useful then return jsonb_build_object('deposited',false,'preserved',true,'reason','not_needed','materials',material); end if;

 ladder:=coalesce(material->'ladder','{}'::jsonb);
 if rarity>=1 and rarity<10 then ladder:=jsonb_set(ladder,'{common}','true'::jsonb,true); end if;
 if rarity>=10 and rarity<50 then ladder:=jsonb_set(ladder,'{uncommon}','true'::jsonb,true); end if;
 if rarity>=50 and rarity<100 then ladder:=jsonb_set(ladder,'{rare}','true'::jsonb,true); end if;
 if rarity>=100 and rarity<1000 then ladder:=jsonb_set(ladder,'{epic}','true'::jsonb,true); end if;
 if rarity>=1000 and rarity<10000 then ladder:=jsonb_set(ladder,'{legendary}','true'::jsonb,true); end if;
 if rarity>=10000 and rarity<100000 then ladder:=jsonb_set(ladder,'{mythic}','true'::jsonb,true); end if;
 if rarity>=100000 and rarity<1000000 then ladder:=jsonb_set(ladder,'{exotic}','true'::jsonb,true); end if;
 if rarity>=1000000 and rarity<10000000 then ladder:=jsonb_set(ladder,'{exalted}','true'::jsonb,true); end if;
 if rarity>=10000000 and rarity<100000000 then ladder:=jsonb_set(ladder,'{cosmic}','true'::jsonb,true); end if;
 if rarity>=100000000 and rarity<1000000000 then ladder:=jsonb_set(ladder,'{transcendent}','true'::jsonb,true); end if;

 material:=jsonb_build_object(
  'selectedCount',coalesce((material->>'selectedCount')::numeric,0)+1,
  'totalMass',coalesce((material->>'totalMass')::numeric,0)+final_weight,
  'legendary',coalesce((material->>'legendary')::numeric,0)+(rarity>=1000 and rarity<10000)::integer,
  'mythic',coalesce((material->>'mythic')::numeric,0)+(rarity>=10000 and rarity<100000)::integer,
  'exotic',coalesce((material->>'exotic')::numeric,0)+(rarity>=100000 and rarity<1000000)::integer,
  'exalted',coalesce((material->>'exalted')::numeric,0)+(rarity>=1000000 and rarity<10000000)::integer,
  'cosmic',coalesce((material->>'cosmic')::numeric,0)+(rarity>=10000000 and rarity<100000000)::integer,
  'transcendent',coalesce((material->>'transcendent')::numeric,0)+(rarity>=100000000 and rarity<1000000000)::integer,
  'wm5',coalesce((material->>'wm5')::numeric,0)+(final_wm>=5)::integer,
  'wm10',coalesce((material->>'wm10')::numeric,0)+(final_wm>=10)::integer,
  'wm30',coalesce((material->>'wm30')::numeric,0)+(final_wm>=30)::integer,
  'effective5b',coalesce((material->>'effective5b')::numeric,0)+(effective>=5000000000)::integer,
  'effective25b',coalesce((material->>'effective25b')::numeric,0)+(effective>=25000000000)::integer,
  'effective100b',coalesce((material->>'effective100b')::numeric,0)+(effective>=100000000000)::integer,
  'under001g',coalesce((material->>'under001g')::numeric,0)+(final_weight<0.01)::integer,
  'over1mg',coalesce((material->>'over1mg')::numeric,0)+(final_weight>1000000)::integer,
  'natural4',coalesce((material->>'natural4')::numeric,0)+(genuine and cardinality(natural_ids)>=4)::integer,
  'quartzUnmutated',coalesce((material->>'quartzUnmutated')::numeric,0)+(gem_name='Quartz' and cardinality(mutation_ids)=0)::integer,
  'seven7s',coalesce((material->>'seven7s')::numeric,0)+(genuine and final_wm>=7 and final_wm<8)::integer,
  'combinedTrophy',coalesce((material->>'combinedTrophy')::numeric,0)+(final_wm>=10 and effective>=25000000000)::integer,
  'ladder',ladder
 );
 v_progress:=jsonb_set(v_progress,'{_paradoxMaterials}',material,true);
 update public.crafting_progress cp set progress=v_progress,updated_at=now() where cp.player_id=p_uid and cp.recipe_id='paradox-pickaxe';
 return jsonb_build_object('deposited',true,'preserved',false,'recipeId','paradox-pickaxe','requirementIndex',1,'progress',v_progress,'materials',material);
end $$;
revoke all on function paradox_private.deposit_specimen(uuid,jsonb,boolean) from public,anon,authenticated;

create or replace function paradox_private.status(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare p public.players%rowtype; material jsonb; trial jsonb; secret boolean; celestial boolean; owned boolean; auto_enabled boolean;
begin
 select * into p from public.players where id=p_uid;
 if not found then raise exception 'player_not_found'; end if;
 material:=paradox_private.materials(p_uid); secret:=paradox_private.has_secret_roll(p_uid);
 select exists(select 1 from public.player_equipment where player_id=p_uid and equipment_id='celestial-pickaxe') into celestial;
 select exists(select 1 from public.player_equipment where player_id=p_uid and equipment_id='paradox-pickaxe') into owned;
 select coalesce(active_auto_craft='paradox-pickaxe',false) into auto_enabled from public.player_crafting where player_id=p_uid;
 trial:=coalesce(p.equipment_state->'paradoxTrial','{"active":false,"completed":false,"rolls":0,"checkpoints":{"legendary":false,"mythic":false,"exotic":false,"exalted":false,"cosmic":false}}'::jsonb);
 return jsonb_build_object('materials',material,'materialsReady',paradox_private.materials_ready(material),
  'historicalSecret',secret,'totalRolls',p.total_rolls,'requiredTotalRolls',999999,'money',p.money,'moneyRequired',4000000000,
  'hasCelestial',celestial,'owned',owned,'autoCraft',coalesce(auto_enabled,false),'trial',trial,
  'readyForTrial',paradox_private.materials_ready(material) and secret and p.total_rolls>=999999 and p.money>=4000000000 and celestial);
end $$;
revoke all on function paradox_private.status(uuid) from public,anon,authenticated;

create or replace function public.get_paradox_pickaxe_status()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid(); begin if uid is null then raise exception 'not_authenticated' using errcode='42501'; end if;
 return paradox_private.status(uid); end $$;
revoke all on function public.get_paradox_pickaxe_status() from public,anon,authenticated;
grant execute on function public.get_paradox_pickaxe_status() to authenticated;

create or replace function public.deposit_paradox_pickaxe_gems(p_gem_ids bigint[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); ids bigint[]; locked_ids bigint[]; gem public.inventory_gems%rowtype; deposited integer:=0; result jsonb;
begin
 if uid is null then raise exception 'not_authenticated' using errcode='42501'; end if;
 select coalesce(array_agg(distinct id order by id),'{}'::bigint[]) into ids from unnest(coalesce(p_gem_ids,'{}'::bigint[])) id;
 if cardinality(ids)=0 or cardinality(ids)>200 then raise exception 'select_between_1_and_200_gems'; end if;
 perform 1 from public.players where id=uid for update;
 if exists(select 1 from public.player_equipment where player_id=uid and equipment_id='paradox-pickaxe') then raise exception 'already_owned'; end if;
 if exists(select 1 from public.players where id=uid and coalesce((equipment_state->'paradoxTrial'->>'active')::boolean,false)) then
  raise exception 'trial_already_active';
 end if;
 select coalesce(array_agg(id order by id),'{}'::bigint[]) into locked_ids from (
  select id from public.inventory_gems where player_id=uid and id=any(ids) and not coalesce(locked,false)
   and not coalesce(museum_locked,false) and gem_name not in ('Enchant Relic','Ancient Relic') order by id for update
 ) selected;
 if locked_ids is distinct from ids then raise exception 'gem_selection_changed'; end if;
 for gem in select * from public.inventory_gems where player_id=uid and id=any(ids) order by id loop
  result:=paradox_private.deposit_specimen(uid,to_jsonb(gem),false);
  if coalesce((result->>'deposited')::boolean,false) then delete from public.inventory_gems where id=gem.id and player_id=uid; deposited:=deposited+1; end if;
 end loop;
 return paradox_private.status(uid)||jsonb_build_object('depositedCount',deposited);
end $$;
revoke all on function public.deposit_paradox_pickaxe_gems(bigint[]) from public,anon,authenticated;
grant execute on function public.deposit_paradox_pickaxe_gems(bigint[]) to authenticated;

create or replace function public.paradox_autocraft_deposit(p_player_id uuid,p_specimen jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.player_crafting where player_id=p_player_id and active_auto_craft='paradox-pickaxe') then
  return jsonb_build_object('deposited',false,'preserved',false,'recipeId',null,'requirementIndex',null);
 end if;
 perform 1 from public.players where id=p_player_id for update;
 if exists(select 1 from public.players where id=p_player_id and coalesce((equipment_state->'paradoxTrial'->>'active')::boolean,false)) then
  return jsonb_build_object('deposited',false,'preserved',true,'reason','trial_active','recipeId','paradox-pickaxe','requirementIndex',1);
 end if;
 return paradox_private.deposit_specimen(p_player_id,p_specimen,true);
end $$;
revoke all on function public.paradox_autocraft_deposit(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.paradox_autocraft_deposit(uuid,jsonb) to service_role;

create or replace function public.start_paradox_trial()
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); p public.players%rowtype; material jsonb; state jsonb;
begin
 if uid is null then raise exception 'not_authenticated' using errcode='42501'; end if;
 select * into p from public.players where id=uid for update;
 if exists(select 1 from public.player_equipment where player_id=uid and equipment_id='paradox-pickaxe') then raise exception 'already_owned'; end if;
 if coalesce((p.equipment_state->'paradoxTrial'->>'active')::boolean,false) then return paradox_private.status(uid); end if;
 material:=paradox_private.materials(uid);
 if not paradox_private.materials_ready(material) or not paradox_private.has_secret_roll(uid) or p.total_rolls<999999
  or p.money<4000000000 or not exists(select 1 from public.player_equipment where player_id=uid and equipment_id='celestial-pickaxe')
 then raise exception 'requirements_not_met'; end if;
 state:=jsonb_set(coalesce(p.equipment_state,'{}'::jsonb),'{paradoxTrial}',
  '{"active":true,"completed":false,"paid":true,"rolls":0,"checkpoints":{"legendary":false,"mythic":false,"exotic":false,"exalted":false,"cosmic":false}}'::jsonb,true);
 update public.players set money=money-4000000000,equipment_state=state where id=uid;
 update public.player_crafting set active_auto_craft=null,updated_at=now() where player_id=uid and active_auto_craft='paradox-pickaxe';
 return paradox_private.status(uid);
end $$;
revoke all on function public.start_paradox_trial() from public,anon,authenticated;
grant execute on function public.start_paradox_trial() to authenticated;

insert into economy_private.cash_paths(function_name,category,direction)
values('start_paradox_trial','equipment_crafting','sink')
on conflict(function_name) do update set category=excluded.category,direction=excluded.direction;

create or replace function public.complete_paradox_trial(p_player_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare state jsonb; trial jsonb; checkpoints jsonb;
begin
 select equipment_state into state from public.players where id=p_player_id for update;
 if not found then raise exception 'player_not_found'; end if;
 if exists(select 1 from public.player_equipment where player_id=p_player_id and equipment_id='paradox-pickaxe') then
  return jsonb_build_object('crafted',false,'alreadyOwned',true);
 end if;
 trial:=state->'paradoxTrial'; checkpoints:=trial->'checkpoints';
 if not coalesce((trial->>'active')::boolean,false) or not coalesce((trial->>'paid')::boolean,false)
  or not coalesce((trial->>'completed')::boolean,false) or coalesce((trial->>'rolls')::integer,0)<10000
  or not coalesce((checkpoints->>'legendary')::boolean,false) or not coalesce((checkpoints->>'mythic')::boolean,false)
  or not coalesce((checkpoints->>'exotic')::boolean,false) or not coalesce((checkpoints->>'exalted')::boolean,false)
  or not coalesce((checkpoints->>'cosmic')::boolean,false) then raise exception 'trial_not_complete'; end if;
 update public.player_equipment set equipped=false where player_id=p_player_id and category='pickaxe' and equipped;
 insert into public.player_equipment(player_id,equipment_id,category,tier,name,luck_bonus,roll_speed_bonus,mutation_chance_bonus,weight_luck_bonus,weight_multiplier_bonus,equipped)
 values(p_player_id,'paradox-pickaxe','pickaxe',16,'Paradox Pickaxe',33,2.1,0.5,4.5,0.7,true)
 on conflict(player_id,equipment_id) do update set equipped=true;
 insert into public.equipment_ownership_history(player_id,equipment_id) values(p_player_id,'paradox-pickaxe') on conflict do nothing;
 state:=jsonb_set(state,'{paradoxTrial,active}','false'::jsonb,true);
 state:=jsonb_set(state,'{paradoxTrial,awarded}','true'::jsonb,true);
 state:=jsonb_set(state,'{paradox}',jsonb_build_object('contradiction',0,'mode','normal','criticalRoll',1),true);
 update public.players set equipment_state=state where id=p_player_id;
 delete from public.crafting_progress where player_id=p_player_id and recipe_id='paradox-pickaxe';
 return jsonb_build_object('crafted',true,'alreadyOwned',false,'equipmentId','paradox-pickaxe');
end $$;
revoke all on function public.complete_paradox_trial(uuid) from public,anon,authenticated;
grant execute on function public.complete_paradox_trial(uuid) to service_role;

commit;
