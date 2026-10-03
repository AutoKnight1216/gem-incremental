import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';

const db=new PGlite();
const q=async(sql,args=[])=>(await db.query(sql,args)).rows;
await db.exec(`
 create role anon; create role authenticated; create role service_role;
 create schema auth; create schema economy_private;
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function public.get_mutation_chance_product(text[]) returns numeric language sql immutable as $$select 1::numeric$$;
 create table public.players(id uuid primary key,money numeric not null default 0,total_rolls bigint not null default 0,equipment_state jsonb not null default '{}');
 create table public.inventory_gems(id bigint generated always as identity primary key,player_id uuid not null,serial_number bigint,gem_name text not null,rarity numeric not null,
  base_weight numeric not null,value_per_gram numeric,rolled_weight_multiplier numeric,rolled_weight numeric,final_weight numeric not null,value numeric not null,
  mutation_ids text[] default '{}',mutation_multipliers numeric[] default '{}',mutation_id text,mutation_multiplier numeric,mutation_chance_multiplier numeric default 1,
  roll_number bigint,luck_at_roll numeric,event_properties jsonb default '{}',locked boolean default false,museum_locked boolean default false,
  source_event_occurrence_id uuid,source_event_key text,value_multiplier_at_roll numeric default 1);
 create table public.game_recipes(id text primary key,recipe jsonb not null);
 create table public.crafting_progress(player_id uuid,recipe_id text,progress jsonb not null default '{}',updated_at timestamptz default now(),primary key(player_id,recipe_id));
 create table public.rare_roll_chat_events(player_id uuid,rarity numeric);
 create table public.best_roll_history(player_id uuid,rarity numeric);
 create table public.player_equipment(id bigint generated always as identity primary key,player_id uuid,equipment_id text,category text,tier integer,name text,
  luck_bonus numeric default 0,roll_speed_bonus numeric default 0,mutation_chance_bonus numeric default 0,weight_luck_bonus numeric default 0,
  weight_multiplier_bonus numeric default 0,equipped boolean default false,unique(player_id,equipment_id));
 create table public.equipment_ownership_history(player_id uuid,equipment_id text,primary key(player_id,equipment_id));
 create table public.player_crafting(player_id uuid primary key,active_auto_craft text,updated_at timestamptz default now());
 create table economy_private.cash_paths(function_name text primary key,category text,direction text);
`);
await db.exec(readFileSync(new URL('../supabase/migrations/20261001123656_paradox_pickaxe.sql',import.meta.url),'utf8'));

const uid='00000000-0000-0000-0000-000000000001';
await q("select set_config('request.jwt.claim.sub',$1,false)",[uid]);
await q('insert into players(id,money,total_rolls) values($1,4000000000,999999)',[uid]);
await q('select public._auction_restore_gem($1,$2)',[uid,{gem_name:'Trade Trophy',rarity:1e8,base_weight:1,final_weight:10,value:25e9,
 mutation_ids:['charged'],natural_mutation_ids:['charged'],effective_rarity:25e9,genuine_roll:true,event_properties:{event:'storm'}}]);
assert.deepEqual((await q("select natural_mutation_ids,effective_rarity,genuine_roll,event_properties from inventory_gems where gem_name='Trade Trophy'"))[0],{
 natural_mutation_ids:['charged'],effective_rarity:'25000000000',genuine_roll:true,event_properties:{event:'storm'}
});
const specimen={gem_name:'Quartz',rarity:100000000,base_weight:1,final_weight:30,value:1,mutation_ids:[],natural_mutation_ids:[],effective_rarity:25000000000,genuine_roll:false};
const overlap=(await q('select paradox_private.deposit_specimen($1,$2,false) result',[uid,specimen]))[0].result.materials;
assert.equal(Number(overlap.transcendent),1);
assert.equal(Number(overlap.wm5),1);assert.equal(Number(overlap.wm10),1);assert.equal(Number(overlap.wm30),1);
assert.equal(Number(overlap.effective5b),1);assert.equal(Number(overlap.effective25b),1);
assert.equal(Number(overlap.quartzUnmutated),1);assert.equal(Number(overlap.combinedTrophy),1);

const complete={...overlap,totalMass:200000000,legendary:20000,mythic:7500,exotic:1500,exalted:750,cosmic:100,transcendent:5,
 wm5:2250,wm10:75,wm30:1,effective5b:25,effective25b:5,effective100b:1,under001g:3,over1mg:3,natural4:1,quartzUnmutated:1000,
 seven7s:7,combinedTrophy:1,ladder:{common:true,uncommon:true,rare:true,epic:true,legendary:true,mythic:true,exotic:true,exalted:true,cosmic:true,transcendent:true}};
await q("update crafting_progress set progress=jsonb_build_object('_paradoxMaterials',$2::jsonb) where player_id=$1",[uid,complete]);
await q('insert into rare_roll_chat_events values($1,1000000000)',[uid]);
await q("insert into player_equipment(player_id,equipment_id,category,tier,name,equipped) values($1,'celestial-pickaxe','pickaxe',15,'Celestial',true)",[uid]);
const started=(await q('select start_paradox_trial() result'))[0].result;
assert.equal(started.trial.active,true);assert.equal(Number(started.money),0);
const finished={...started.trial,active:true,paid:true,completed:true,rolls:10000,checkpoints:{legendary:true,mythic:true,exotic:true,exalted:true,cosmic:true}};
await q("update players set equipment_state=jsonb_set(equipment_state,'{paradoxTrial}',$2::jsonb,true) where id=$1",[uid,finished]);
const award=(await q('select complete_paradox_trial($1) result',[uid]))[0].result;
assert.equal(award.crafted,true);
assert.deepEqual((await q("select luck_bonus,roll_speed_bonus,mutation_chance_bonus,weight_luck_bonus,weight_multiplier_bonus,equipped from player_equipment where player_id=$1 and equipment_id='paradox-pickaxe'",[uid]))[0],{
 luck_bonus:'33',roll_speed_bonus:'2.1',mutation_chance_bonus:'0.5',weight_luck_bonus:'4.5',weight_multiplier_bonus:'0.7',equipped:true
});
console.log('Paradox database migration: overlap deposits, authoritative gates, $4B trial start and atomic award passed.');
