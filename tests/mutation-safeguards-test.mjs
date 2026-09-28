import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const migration = readFileSync(
  new URL("../supabase/migrations/20260927054853_cap_misty_stacks_at_three.sql", import.meta.url),
  "utf8"
);
const rollSource = readFileSync(
  new URL("../supabase/functions/roll/index.ts", import.meta.url),
  "utf8"
);

assert.match(rollSource, /MAX_MISTY_STACKS = 3/);
assert.match(rollSource, /MAX_COMBINED_MUTATION_VALUE_MULTIPLIER = 100000/);
assert.equal(
  (rollSource.match(/capCombinedMutationValueMultiplier\(/g) ?? []).length,
  4,
  "the cap helper is defined and applied to primary, duplicate, and Breakneck specimens"
);
assert.doesNotMatch(migration, /inventory_gems|player_gem_mutation_combinations|gem_discover/i);

const db = new PGlite();
await db.exec(`
  create table public.players (
    id uuid primary key,
    misty_mutation_boost_stacks integer not null default 0
  );
  insert into public.players values
    ('00000000-0000-0000-0000-000000000001', 2),
    ('00000000-0000-0000-0000-000000000002', 5);
`);
await db.exec(migration);

const rows = (await db.query(
  "select misty_mutation_boost_stacks from public.players order by id"
)).rows;
assert.deepEqual(rows.map(row => Number(row.misty_mutation_boost_stacks)), [2, 3]);
await assert.rejects(
  db.exec("insert into public.players values ('00000000-0000-0000-0000-000000000003', 4)"),
  /players_misty_mutation_boost_stacks_max_three/
);

console.log("Mutation safeguard migration caps live Misty state without touching historical discoveries.");
