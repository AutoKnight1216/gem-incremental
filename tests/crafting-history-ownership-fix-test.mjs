import assert from "node:assert/strict";
import { PGlite } from "@electric-sql/pglite";
import { readFileSync } from "node:fs";
import { ownsCraftedEquipment } from "../src/logic/crafting.js";

const migration = readFileSync(
  new URL("../supabase/migrations/20260930134046_preserve_historical_crafting_progress.sql", import.meta.url),
  "utf8",
);

const higherTier = [{ equipment_id: "eternity-pickaxe", category: "pickaxe", tier: 17 }];
assert.equal(ownsCraftedEquipment({ id: "empyrean-pickaxe" }, higherTier), false);
assert.equal(ownsCraftedEquipment({ id: "eternity-pickaxe" }, higherTier), true);
assert.equal(
  ownsCraftedEquipment({ id: "omnidimensional-vault" }, [{ equipment_id: "dimensional-vault" }]),
  true,
);

const db = new PGlite();
await db.exec(`
  create role anon;
  create role authenticated;
  create role service_role;
  create table players (
    id uuid primary key,
    equipment_state jsonb not null default '{}'::jsonb,
    total_rolls bigint not null default 0,
    equipment_genuine_rolls bigint not null default 0,
    lifetime_earnings numeric not null default 0
  );
  create table equipment_ownership_history (player_id uuid, equipment_id text);
  create table inventory_gems (
    player_id uuid, rarity numeric, base_weight numeric, final_weight numeric
  );
`);
await db.exec(migration);
await db.exec(migration);

const uid = "00000000-0000-0000-0000-000000000001";
await db.query(
  `insert into players(id, equipment_state, total_rolls, equipment_genuine_rolls)
   values($1, $2, 371123, 94300)`,
  [uid, { spool: 200, batchHistory: { raw5m: 8, raw10m: 3, heavy5: 250 } }],
);

await db.query(
  `update players set equipment_state=$2 where id=$1`,
  [uid, { spool: 0, batchHistory: { raw5m: 2, raw10m: 4 } }],
);
const [{ equipment_state: state }] = (await db.query("select equipment_state from players where id=$1", [uid])).rows;
assert.equal(state.spool, 0);
assert.deepEqual(state.batchHistory, { raw5m: 8, raw10m: 4, heavy5: 250 });

const [{ progress }] = (await db.query("select equipment_batch_progress($1) progress", [uid])).rows;
assert.equal(progress.genuineRolls, 371123);

await db.close();
console.log("Crafting history remains monotonic and crafted status requires exact current ownership.");
