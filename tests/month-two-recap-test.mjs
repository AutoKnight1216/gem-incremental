import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";

const db = new PGlite();
await db.exec(`
create role anon; create role authenticated; create role service_role;
create schema auth; create schema month_one_private;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
create table players(id uuid primary key,username text,created_at timestamptz,
 leaderboard_hidden boolean default false,total_rolls bigint default 0,
 lifetime_earnings numeric default 0,lifetime_money_burned numeric default 0,money numeric default 0);
create table bank_accounts(player_id uuid primary key,balance numeric);
create table system_account_exclusions(player_id uuid primary key,exclude_from_economy boolean default true,
 exclude_from_announcements boolean default true,reason text,created_at timestamptz default now());
create table minigame_scores(run_id uuid primary key,player_id uuid,game text,score numeric,
 tie1 numeric,tie2 numeric,achieved_at timestamptz);
create table best_roll_history(id bigint primary key,player_id uuid,username text,gem_name text,
 rarity numeric,raw_luck numeric,base_luck numeric,final_weight numeric,value numeric,
 mutation_ids text[],effective_rarity numeric,roll_number bigint,created_at timestamptz);
create table roll_weight_history(id bigint primary key,player_id uuid,username text,gem_name text,
 final_weight numeric,base_rarity numeric,mutation_ids text[],created_at timestamptz);
create table private_feature_gems(id uuid primary key default gen_random_uuid(),name text unique,title text default '',
 rarity double precision,base_weight numeric,value_per_gram numeric,description text default '',metadata jsonb default '{}',
 hide_rarity_until_discovered boolean default false,affected_by_luck boolean default true,enabled boolean default true,
 sort_order integer default 0,starts_at timestamptz,ends_at timestamptz,availability_mode text default 'always',
 availability_timezone text default 'Asia/Singapore',special_gem boolean default false,updated_at timestamptz default now());
create table month_one_private.cache(singleton boolean primary key,generated_at timestamptz,final boolean,payload jsonb);
create function public.roll_finish_bookkeeping(p_player_id uuid,p_phase text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_lifetime jsonb := '{}'::jsonb; v_errors jsonb := '[]'::jsonb;
begin
  if p_phase = 'critical' then
    return jsonb_build_object(
      'lifetimeStats', v_lifetime,
      'errors', v_errors
    );
  end if;
  return jsonb_build_object('errors',v_errors);
end $$;
insert into players values
 ('11111111-1111-1111-1111-111111111111','Original','2026-08-10',false,150,1500,150,900),
 ('22222222-2222-2222-2222-222222222222','Newcomer','2026-09-12',false,25,250,25,80);
insert into bank_accounts values('11111111-1111-1111-1111-111111111111',50);
insert into minigame_scores values('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','11111111-1111-1111-1111-111111111111','mine-sweeper',-1000,0,0,'2026-09-20');
insert into best_roll_history values(1,'11111111-1111-1111-1111-111111111111','Original','Ruby',1000,2,1,20,500,ARRAY['smooth'],100000,140,'2026-09-20');
insert into roll_weight_history values(1,'11111111-1111-1111-1111-111111111111','Original','Ruby',30,1000,ARRAY[]::text[],'2026-09-20');
with people as (
 select case when i=1 then '11111111-1111-1111-1111-111111111111'::uuid else md5(i::text)::uuid end id,i
 from generate_series(1,124) i
), personal as (
 select jsonb_object_agg(id::text,jsonb_build_object('username','P'||i,'rolls',case when i=1 then 100 else 0 end,
  'earned',case when i=1 then 1000 else 0 end,'burned',case when i=1 then 100 else 0 end,
  'rollRank',i,'earningsRank',i,'joinNumber',i,'records','{}'::jsonb,'minigames','[]'::jsonb)) payload from people
)
insert into month_one_private.cache values(true,'2026-09-07 16:00+00',true,
 jsonb_build_object('global',jsonb_build_object('totals',jsonb_build_object('rolls',4714512,'players',124,'earned',10000,'burned',1000,'median_rolls',10,'rollers_1k',1,'rollers_10k',0,'rollers_100k',0),'records','{}'::jsonb,'minigameRuns',10,'minigamePlayers',3),
 'personal',(select payload from personal)));
`);

const migration = await fs.readFile(new URL("../supabase/migrations/20260927052133_reusable_recap_month_two_anniversary.sql", import.meta.url), "utf8");
await db.exec(migration);

assert.equal((await db.query("select count(*)::int n from recap_private.period_personal_baselines where period_id='month-2'")).rows[0].n, 124);
assert.equal((await db.query("select count(*)::int n from month_one_private.cache")).rows[0].n, 1);
const built = (await db.query("select recap_private.build('month-2') data")).rows[0].data;
assert.equal(built.global.totals.rolls, 75);
assert.equal(built.global.totals.new_players, 1);
assert.equal(built.personal["11111111-1111-1111-1111-111111111111"].monthTwoRolls, 50);
assert.equal(built.personal["22222222-2222-2222-2222-222222222222"].newPlayer, true);
assert.equal(built.personal["22222222-2222-2222-2222-222222222222"].monthOne, null);
assert.equal(built.global.records.raw.rawRarity, 500);
assert.equal(built.global.records.weight.weight, 30);
assert.equal(built.global.minigames[0].best_score, -1000);

await db.exec("set request.jwt.claim.role='service_role'");
await db.query(`select recap_private.capture_roll(
 '11111111-1111-1111-1111-111111111111',
 '{"gemName":"Diamond","rarity":10000,"rawLuck":1,"effectiveRarity":1000000,"finalWeight":40,"value":800,"mutationIds":["smooth","clear"],"rollNumber":151}'::jsonb)`);
assert.equal((await db.query("select (recap_private.build('month-2')#>>'{global,records,raw,gem}') gem")).rows[0].gem, "Diamond");
await db.exec("update players set total_rolls=175 where id='11111111-1111-1111-1111-111111111111'");
assert.equal((await db.query("select (recap_private.build('month-2')#>>'{global,totals,rolls}')::int rolls")).rows[0].rolls, 100);

const duolite = (await db.query("select * from private_feature_gems where name='Duolite'")).rows[0];
assert.equal(duolite.rarity, 2020026);
assert.equal(Number(duolite.base_weight), 202);
assert.equal(Number(duolite.value_per_gram), 2026);
assert.equal(duolite.affected_by_luck, true);
assert.equal(duolite.special_gem, false);
assert.equal(duolite.metadata.indexMarker, "LIMITED • MONTH TWO 2026");
assert.match((await db.query("select pg_get_functiondef('public.roll_finish_bookkeeping(uuid,text,jsonb)'::regprocedure) definition")).rows[0].definition, /recap_private\.capture_roll/);

await db.exec(`update recap_private.periods set statistics_cutoff=clock_timestamp()-interval '1 second',
 publishes_at=clock_timestamp()-interval '1 second',finalizes_at=clock_timestamp()+interval '1 day' where id='month-2';
 set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';`);
const response = (await db.query("select public.get_recap_period('month-2') data")).rows[0].data;
assert.equal(response.status, "finalizing");
assert.equal(response.personal.monthTwoRolls, 75);
const intro = (await db.query("select public.get_month_two_anniversary_intro(false) data")).rows[0].data;
assert.equal(intro.show, true);
assert.equal((await db.query("select public.get_month_two_anniversary_intro(false) data")).rows[0].data.show, false);

await db.exec("set role authenticated");
await assert.rejects(db.query("select * from recap_private.period_snapshots"), /permission denied/);
console.log("Month Two: reusable periods, frozen baseline deltas, records, Duolite, auth isolation and once-per-account intro passed.");
await db.close();
