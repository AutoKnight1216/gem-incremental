import assert from "node:assert/strict";
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";

const migration = readFileSync(
  new URL("../supabase/migrations/20261001153230_global_cash_all_lifetime_earnings.sql", import.meta.url),
  "utf8",
);
const db = new PGlite();
const query = async (sql, params = []) => (await db.query(sql, params)).rows;

await db.exec(`
  create role anon;
  create role authenticated;
  create role service_role;
  create table players (
    id uuid primary key,
    lifetime_earnings numeric not null default 0,
    money numeric not null default 0
  );
  create table system_account_exclusions (
    player_id uuid primary key,
    exclude_from_economy boolean not null default true
  );
  create table bank_accounts (player_id uuid primary key, balance numeric not null default 0);
  create table player_presence (player_id uuid primary key, last_seen_at timestamptz);
  create table global_cash_events (
    id bigint generated always as identity primary key,
    player_name text,
    gem_name text,
    amount numeric,
    created_at timestamptz default now()
  );
  create table global_cash_history (
    id bigint generated always as identity primary key,
    at timestamptz not null default now(),
    lifetime double precision not null,
    money double precision not null,
    bank double precision not null
  );
  create table cash_market_tick (
    id smallint primary key default 1 check (id = 1),
    lifetime double precision not null default 0,
    money double precision not null default 0,
    bank double precision not null default 0,
    at timestamptz not null default '-infinity'
  );
  insert into cash_market_tick(id) values (1);
`);

const ids = [
  "00000000-0000-0000-0000-000000000001",
  "00000000-0000-0000-0000-000000000002",
  "00000000-0000-0000-0000-000000000003",
];
await query(
  `insert into players(id, lifetime_earnings, money)
   values ($1,100,10),($2,200,20),($3,300,30)`,
  ids,
);
await query("insert into system_account_exclusions(player_id) values ($1)", [ids[2]]);
await query("insert into bank_accounts values ($1,1),($2,2),($3,3)", ids);

await db.exec(migration);

assert.equal(Number((await query("select get_global_cash() total"))[0].total), 600);
const feed = (await query("select get_global_cash_feed() feed"))[0].feed;
assert.equal(Number(feed.total), 600);

const tick = (await query("select get_cash_market_tick() tick"))[0].tick;
assert.equal(Number(tick.lifetime), 600);
assert.equal(Number(tick.money), 30);
assert.equal(Number(tick.bank), 3);

const latest = (await query(
  "select lifetime, money, bank from global_cash_history order by id desc limit 1",
))[0];
assert.deepEqual(
  [Number(latest.lifetime), Number(latest.money), Number(latest.bank)],
  [600, 30, 3],
);

await db.close();
console.log("Global cash includes every player's lifetime earnings across all endpoints.");
