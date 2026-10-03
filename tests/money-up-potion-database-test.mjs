import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const db = new PGlite();
const migration = readFileSync(
  new URL("../supabase/migrations/20260920120000_money_up_potion.sql", import.meta.url),
  "utf8"
);
const rebalanceMigration = readFileSync(
  new URL("../supabase/migrations/20260930034420_rebalance_money_up_potions.sql", import.meta.url),
  "utf8"
);
const playerId = "00000000-0000-4000-8000-000000000001";
const assertMoney = (actual, expected, message) =>
  assert.ok(Math.abs(Number(actual) - expected) < 1e-9, `${message}: expected ${expected}, received ${actual}`);

await db.exec(`
  create role anon;
  create role authenticated;
  create role service_role;
  create schema auth;
  create function auth.uid() returns uuid language sql stable as
    $$select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid$$;
  create table public.players(
    id uuid primary key,
    username text,
    money double precision not null default 0,
    lifetime_earnings double precision not null default 0,
    total_rolls bigint not null default 0
  );
  create table public.inventory_gems(
    id bigint primary key,
    player_id uuid not null,
    gem_name text not null,
    value double precision not null,
    locked boolean not null default false
  );
  create table public.player_boosts(
    player_id uuid not null,
    family text not null,
    tier integer not null,
    effect_value numeric not null,
    expires_at timestamptz not null,
    updated_at timestamptz,
    primary key(player_id, family)
  );
  create table public.game_consumables(
    id text primary key,
    name text,
    family text,
    tier integer,
    effect_value numeric,
    duration_seconds integer,
    purchasable boolean,
    shop_price numeric
  );
  create table public.game_recipes(id text primary key, recipe jsonb not null);
  create table public.crafting_progress(
    player_id uuid not null,
    recipe_id text not null,
    progress jsonb not null default '{}'::jsonb,
    primary key(player_id, recipe_id)
  );
  create table public.player_consumables(
    player_id uuid not null,
    consumable_id text not null,
    quantity integer not null default 0,
    updated_at timestamptz,
    primary key(player_id, consumable_id)
  );
  create table public.global_cash_events(player_name text, gem_name text, amount double precision);
  create function public.equipment_gem_sell_multiplier(uuid) returns numeric language sql stable as $$select 1::numeric$$;
  insert into public.players(id, username) values ('${playerId}', 'Potion Tester');
  select set_config('request.jwt.claim.sub', '${playerId}', false);
`);

await db.exec(migration);

await db.query(
  "insert into public.player_boosts(player_id, family, tier, effect_value, expires_at) values($1, 'gemValue', 1, 1.5, now() + interval '1 minute')",
  [playerId]
);
await db.exec(rebalanceMigration);
await db.query(
  "insert into public.inventory_gems(id, player_id, gem_name, value) values(1, $1, 'Quartz', 100)",
  [playerId]
);
let money = (await db.query(
  "select public.sell_inventory_gem($1, 1, 'auto') as money",
  [playerId]
)).rows[0].money;
assertMoney(money, 110, "an active Money Up Potion must multiply automatic sales");

await db.query(
  "insert into public.inventory_gems(id, player_id, gem_name, value) values(2, $1, 'Quartz', 100)",
  [playerId]
);
money = (await db.query(
  "select public.sell_inventory_gem($1, 2, 'manual') as money",
  [playerId]
)).rows[0].money;
assertMoney(money, 210, "manual sales must not receive the auto-sell multiplier");

await db.query("update public.player_boosts set expires_at = now() - interval '1 second' where player_id = $1", [playerId]);
await db.query(
  "insert into public.inventory_gems(id, player_id, gem_name, value) values(3, $1, 'Quartz', 100)",
  [playerId]
);
money = (await db.query(
  "select public.sell_inventory_gem($1, 3, 'auto') as money",
  [playerId]
)).rows[0].money;
assertMoney(money, 310, "expired Money Up Potions must not affect automatic sales");

const consumables = (await db.query(
  "select id, family, effect_value, duration_seconds from public.game_consumables where id like 'money-up-potion%' order by id"
)).rows.map((row) => ({ ...row, effect_value: Number(row.effect_value) }));
assert.deepEqual(consumables, [
  { id: "money-up-potion", family: "gemValue", effect_value: 1.1, duration_seconds: 60 },
  { id: "money-up-potion-2", family: "gemValue", effect_value: 1.25, duration_seconds: 60 }
]);

const recipes = (await db.query(
  "select id, recipe from public.game_recipes where id like 'money-up-potion%' order by id"
)).rows;
assert.equal(Number(recipes[0].recipe.moneyCost), 25000);
assert.equal(Number(recipes[0].recipe.reward.effectValue), 1.1);
assert.equal(Number(recipes[1].recipe.moneyCost), 100000);
assert.equal(Number(recipes[1].recipe.reward.effectValue), 1.25);
assert.deepEqual(
  recipes[1].recipe.requirements.find((requirement) => requirement.consumableId === "money-up-potion"),
  { type: "consumable", consumableId: "money-up-potion", amount: 3 }
);

await db.query("update public.players set money = 1000000 where id = $1", [playerId]);
await db.query(`
  insert into public.player_consumables(player_id, consumable_id, quantity, updated_at)
  values
    ($1, 'lucky-potion-1', 5, now()),
    ($1, 'fortune-potion-1', 5, now()),
    ($1, 'lucky-potion-2', 5, now()),
    ($1, 'fortune-potion-2', 5, now())
`, [playerId]);

const tierOneCraft = (await db.query(
  "select public.craft_consumable_recipe('money-up-potion') as result"
)).rows[0].result;
assert.equal(tierOneCraft.success, true);
assert.equal(tierOneCraft.consumableId, "money-up-potion");
assert.equal(
  (await db.query("select count(*)::integer as count from public.crafting_progress where player_id = $1", [playerId])).rows[0].count,
  0,
  "consumable-only recipes must craft without a deposited-progress row"
);

await db.query(`
  update public.player_consumables
  set quantity = 3
  where player_id = $1 and consumable_id = 'money-up-potion'
`, [playerId]);
const tierTwoCraft = (await db.query(
  "select public.craft_consumable_recipe('money-up-potion-2') as result"
)).rows[0].result;
assert.equal(tierTwoCraft.success, true);
assert.equal(tierTwoCraft.consumableId, "money-up-potion-2");
assert.equal(
  Number((await db.query("select money from public.players where id = $1", [playerId])).rows[0].money),
  875000,
  "both recipe costs must be charged"
);
assert.equal(
  Number((await db.query("select quantity from public.player_consumables where player_id = $1 and consumable_id = 'money-up-potion'", [playerId])).rows[0].quantity),
  0,
  "Money Up Potion II must consume three Tier I potions"
);

await db.query(`
  insert into public.game_recipes(id, recipe)
  values (
    'gem-gated-potion',
    '{
      "id": "gem-gated-potion",
      "requirements": [{"type": "gem-count", "gem": "Quartz", "amount": 1}],
      "moneyCost": 0,
      "reward": {"type": "consumable", "id": "gem-gated-potion"}
    }'::jsonb
  )
`);
await assert.rejects(
  db.query("select public.craft_consumable_recipe('gem-gated-potion')"),
  /requirements_not_met/,
  "missing progress must not bypass deposited gem requirements"
);

await db.close();
console.log("Money Up Potion database checks passed");
