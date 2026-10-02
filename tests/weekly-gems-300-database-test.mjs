import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const db = new PGlite();
const migration = readFileSync(
  new URL("../supabase/migrations/20261002082056_weekly_gem_catalogue_300.sql", import.meta.url),
  "utf8"
);
const uid = "00000000-0000-0000-0000-000000000001";

await db.exec(`
  create role anon;
  create role authenticated;
  create role service_role;
  create schema auth;
  create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
  $$;

  create table public.players (
    id uuid primary key,
    username text default 'Tester',
    inventory_capacity integer not null default 50,
    money double precision not null default 0,
    lifetime_earnings double precision not null default 0,
    roll_lease_id uuid
  );
  create table public.player_research_effects (player_id uuid primary key, inventory_bonus integer default 0);
  create table public.player_boosts (player_id uuid, family text, effect_value double precision, expires_at timestamptz);
  create table public.global_cash_events (player_name text, gem_name text, amount double precision);
  create table public.private_feature_gems (
    id uuid primary key default gen_random_uuid(),
    name text not null unique,
    rarity double precision not null check (rarity > 0),
    base_weight numeric not null check (base_weight > 0),
    value_per_gram numeric not null check (value_per_gram >= 0),
    sort_order integer not null default 0,
    enabled boolean not null default true,
    starts_at timestamptz,
    ends_at timestamptz,
    metadata jsonb not null default '{}',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    description text not null default '',
    hide_rarity_until_discovered boolean not null default false,
    title text not null default '',
    availability_mode text not null default 'always',
    daily_start_time time,
    daily_end_time time,
    availability_timezone text not null default 'Asia/Singapore',
    affected_by_luck boolean not null default true,
    required_event_key text,
    special_gem boolean not null default false,
    daily_time_windows jsonb
  );
  create table public.inventory_gems (
    id bigint generated always as identity primary key,
    player_id uuid not null references public.players(id),
    gem_name text not null,
    rarity integer not null check (rarity > 0),
    base_weight double precision not null,
    value_per_gram double precision not null,
    rolled_weight_multiplier double precision not null,
    rolled_weight double precision not null,
    final_weight double precision not null,
    value double precision not null,
    locked boolean not null default false,
    museum_locked boolean not null default false,
    luck_at_roll numeric,
    mutation_multiplier numeric not null default 1,
    mutation_ids text[] not null default '{}',
    mutation_multipliers jsonb not null default '{}',
    mutation_chance_multiplier numeric not null default 1,
    natural_mutation_ids text[] not null default '{}',
    effective_rarity numeric,
    genuine_roll boolean not null default false
  );
  create table public.player_gem_mutation_combinations (
    id bigint generated always as identity primary key,
    player_id uuid not null,
    gem_name text not null,
    combination_key text not null default 'none',
    mutation_ids text[] not null default '{}',
    mutation_multipliers jsonb not null default '{}',
    total_found bigint not null default 1,
    highest_value numeric not null default 0,
    first_discovered_at timestamptz not null default now(),
    last_discovered_at timestamptz not null default now(),
    unique(player_id, gem_name, combination_key)
  );
  create function public.record_gem_mutation_combination(uuid,text,text,text[],jsonb,numeric)
  returns public.player_gem_mutation_combinations language plpgsql security definer as $$
  declare result public.player_gem_mutation_combinations;
  begin
    insert into public.player_gem_mutation_combinations(player_id,gem_name,combination_key,mutation_ids,mutation_multipliers,highest_value)
    values($1,$2,'none',$4,$5,$6)
    on conflict(player_id,gem_name,combination_key) do update set total_found=player_gem_mutation_combinations.total_found+1
    returning * into result;
    return result;
  end $$;
  create function public.equipment_gem_sell_multiplier(uuid) returns double precision language sql stable as $$ select 1::double precision $$;
`);

await db.query(`
  insert into public.private_feature_gems(name,rarity,base_weight,value_per_gram,description,metadata,sort_order)
  select case when n=1 then 'π' else 'Existing '||n end, 100+n, 1, 1, '', '{}', n
  from generate_series(1,281) n
`);
await db.exec(migration);

const catalogue = (await db.query(`
  select name, rarity, metadata, affected_by_luck, special_gem
  from public.private_feature_gems
  where enabled
  order by (metadata->>'catalogueOrder')::integer nulls first
`)).rows;
assert.equal(catalogue.length, 300);
for (const name of [
  "e", "i", "Jade", "Verity", "Calmarite", "Incandescity",
  "Långbanshyttanite", "Uvarovite", "Rainbow Lattice Sunstone",
  "Chkalovite", "Nabesite", "Neptunite", "Kuannersuite-(Ce)",
  "Chromaflux", "Parallax", "Liminalite", "Chronofracture", "300", "Ore+"
]) assert.ok(catalogue.some((gem) => gem.name === name), `${name} missing`);

const milestone = catalogue.find((gem) => gem.name === "300");
assert.equal(milestone.metadata.catalogueOrder, 300);
const imaginary = catalogue.find((gem) => gem.name === "i");
assert.equal(Number(imaginary.rarity), 1, "positive storage rarity preserves the DB constraint");
assert.equal(imaginary.metadata.displayRarity, -1);
assert.equal(imaginary.metadata.normalRng, false);
assert.equal(imaginary.metadata.automaticConsumptionProtected, true);
assert.equal(imaginary.affected_by_luck, false);
assert.equal(imaginary.special_gem, true);

assert.equal((await db.query("select gem_automatic_consumption_protected('i') value")).rows[0].value, true);
assert.equal((await db.query("select gem_automatic_consumption_protected('Quartz') value")).rows[0].value, false);

await db.query("insert into public.players(id,inventory_capacity) values($1,10)", [uid]);
await db.query(`
  insert into public.player_gem_mutation_combinations(player_id,gem_name)
  values($1,'π'),($1,'e')
`, [uid]);
await db.query("select set_config('request.jwt.claim.sub',$1,false)", [uid]);
await db.exec("set role authenticated");
const claim = (await db.query("select public.claim_anomalous_i('i') value")).rows[0].value;
assert.equal(claim.claimed, true);
assert.equal(claim.displayRarity, -1);
await assert.rejects(() => db.query("select public.claim_anomalous_i('i')"), /already_claimed/);
await db.exec("reset role");

const specimen = (await db.query("select gem_name,rarity,locked from public.inventory_gems where player_id=$1", [uid])).rows[0];
assert.deepEqual(specimen, { gem_name: "i", rarity: 1, locked: true });
assert.equal(Number((await db.query("select count(*) value from private.gem_puzzle_claims where player_id=$1", [uid])).rows[0].value), 1);
assert.equal(Number((await db.query("select count(*) value from public.player_gem_mutation_combinations where player_id=$1 and gem_name='i'", [uid])).rows[0].value), 1);

await db.close();
console.log("Weekly gems database: 300 live entries, positive-storage/negative-display i, one-time locked claim, and reusable protection passed.");
