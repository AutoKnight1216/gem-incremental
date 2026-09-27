import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const migration = readFileSync(
  new URL("../supabase/migrations/20260927141249_gem_sales_only_lifetime_earnings_leaderboard.sql", import.meta.url),
  "utf8"
);

assert.match(migration, /category = 'gem_sales'/);
assert.match(migration, /economy_private\.player_gem_sale_earnings/);
assert.match(migration, /get_lifetime_earnings_leaderboard/);
assert.match(migration, /grant execute on function public\.get_lifetime_earnings_leaderboard\(integer\)[\s\S]*to service_role/);
assert.doesNotMatch(migration, /to anon, authenticated/);
assert.doesNotMatch(
  migration.slice(migration.indexOf("create or replace function public.get_lifetime_earnings_leaderboard")),
  /p\.lifetime_earnings/
);

const db = new PGlite();
await db.exec(`
  create role anon;
  create role authenticated;
  create role service_role;
  create schema economy_private;
  create table players(
    id uuid primary key,
    username text,
    leaderboard_hidden boolean not null default false,
    lifetime_earnings numeric not null default 0
  );
  create table economy_cash_ledger(
    id bigint generated always as identity primary key,
    created_at timestamptz not null default statement_timestamp(),
    player_id uuid,
    account text not null,
    amount numeric not null,
    direction text not null,
    category text not null
  );
`);

const seller = "00000000-0000-0000-0000-000000000001";
const rewarded = "00000000-0000-0000-0000-000000000002";
const hidden = "00000000-0000-0000-0000-000000000003";
await db.query(`
  insert into players(id,username,leaderboard_hidden,lifetime_earnings) values
    ($1,'Gem Seller',false,1000500),
    ($2,'Reward Collector',false,9000000),
    ($3,'Hidden Seller',true,2000000)
`, [seller, rewarded, hidden]);
await db.query(`
  insert into economy_cash_ledger(player_id,account,amount,direction,category) values
    ($1,'wallet',500,'source','gem_sales'),
    ($1,'wallet',1000000,'source','expedition_rewards'),
    ($2,'wallet',9000000,'source','admin_system_rewards'),
    ($3,'wallet',2000000,'source','gem_sales')
`, [seller, rewarded, hidden]);

await db.exec(migration);

let rows = await db.query("select * from get_lifetime_earnings_leaderboard(100)");
assert.deepEqual(rows.rows.map((row) => [
  Number(row.rank), row.username, Number(row.lifetime_earnings)
]), [[1, "Gem Seller", 500]]);

// New gem sales advance the leaderboard; every other source remains excluded.
await db.query(`
  insert into economy_cash_ledger(player_id,account,amount,direction,category) values
    ($1,'wallet',250,'source','gem_sales'),
    ($1,'wallet',5000000,'source','season_rewards'),
    ($2,'wallet',10000000,'source','bank_interest')
`, [seller, rewarded]);
rows = await db.query("select * from get_lifetime_earnings_leaderboard(100)");
assert.deepEqual(rows.rows.map((row) => [
  Number(row.rank), row.username, Number(row.lifetime_earnings)
]), [[1, "Gem Seller", 750]]);

await db.close();
console.log("Gem-sale-only lifetime earnings leaderboard passed.");
