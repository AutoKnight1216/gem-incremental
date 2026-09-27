import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const migration = readFileSync(
  new URL("../supabase/migrations/20260927085527_persist_rare_roll_details_and_limit_categories.sql", import.meta.url),
  "utf8"
);
const backend = readFileSync(new URL("../src/backend/rareRolls.js", import.meta.url), "utf8");

assert.match(migration, /add column if not exists luck_at_roll numeric/);
assert.match(migration, /add column if not exists serial_number bigint/);
assert.match(migration, /partition by category/);
assert.match(migration, /new\.raw_luck/);
assert.match(migration, /new\.serial_number/);
assert.match(backend, /loadRareRolls\(limitPerCategory = 5\)/);
assert.match(backend, /p_limit: safeLimit/);
assert.doesNotMatch(backend, /p_limit: safeLimit \* 2/);

const db = new PGlite();
await db.exec(`
  create role anon;
  create role authenticated;
  create table player_titles(player_id uuid primary key, title text, color text);
  create table private_feature_gems(name text primary key, metadata jsonb);
  create table best_roll_history(
    id bigint generated always as identity primary key,
    player_id uuid not null,
    username text not null,
    gem_name text not null,
    rarity numeric not null,
    mutation_ids text[] default '{}',
    base_luck numeric,
    raw_luck numeric,
    serial_number bigint,
    created_at timestamptz not null default now()
  );
  create table rare_roll_chat_events(
    id bigint generated always as identity primary key,
    source_type text not null,
    source_id bigint,
    player_id uuid not null,
    username text not null,
    gem_name text not null,
    rarity numeric not null,
    effective_rarity numeric not null,
    mutation_ids text[] not null default '{}',
    base_luck numeric,
    created_at timestamptz not null default now()
  );
  create unique index rare_roll_chat_events_source_unique
    on rare_roll_chat_events(source_type, source_id) where source_id is not null;
  create function get_mutation_chance_product(text[]) returns numeric
    language sql immutable as $$ select 1::numeric $$;
`);

const player = "00000000-0000-0000-0000-000000000001";

// One linked legacy event proves migration backfill and durable read fields.
const linked = await db.query(`
  insert into best_roll_history(
    player_id,username,gem_name,rarity,mutation_ids,base_luck,raw_luck,serial_number
  ) values($1,'Roller','Linked Base',100000000,'{}',10,1234.56,77)
  returning id
`, [player]);
await db.query(`
  insert into rare_roll_chat_events(
    source_type,source_id,player_id,username,gem_name,rarity,effective_rarity,mutation_ids,base_luck
  ) values('history',$1,$2,'Roller','Linked Base',100000000,100000000,'{}',10)
`, [linked.rows[0].id, player]);

// An orphaned legacy event has lost its history row. Its event-local Luck still
// remains displayable after migration instead of disappearing with the join.
await db.query(`
  insert into rare_roll_chat_events(
    source_type,source_id,player_id,username,gem_name,rarity,effective_rarity,mutation_ids,base_luck
  ) values('history',999999,$1,'Roller','Orphan Base',145000000,145000000,'{}',88)
`, [player]);

await db.exec(migration);

const durable = await db.query(`
  select gem_name,luck_at_roll,serial_number
  from get_rare_roll_chat_history(5)
  where gem_name in ('Linked Base','Orphan Base')
  order by gem_name
`);
assert.deepEqual(durable.rows.map((row) => [
  row.gem_name,
  Number(row.luck_at_roll),
  row.serial_number == null ? null : Number(row.serial_number)
]), [
  ["Linked Base", 1234.56, 77],
  ["Orphan Base", 88, null]
]);

// Insert six of each category. A per-category limit of five must return ten
// total rather than allowing the newest category to starve the other one.
for (let index = 0; index < 6; index += 1) {
  await db.query(`
    insert into rare_roll_chat_events(
      source_type,player_id,username,gem_name,rarity,effective_rarity,mutation_ids,
      base_luck,luck_at_roll,serial_number,created_at
    ) values('test',$1,'Roller',$2,100000000,100000000,'{}',1,2,$3,now() + $4 * interval '1 second')
  `, [player, `Base ${index}`, index + 1, index]);
  await db.query(`
    insert into rare_roll_chat_events(
      source_type,player_id,username,gem_name,rarity,effective_rarity,mutation_ids,
      base_luck,luck_at_roll,serial_number,created_at
    ) values('test',$1,'Roller',$2,1000,10000000000,array['special'],1,2,$3,now() + $4 * interval '1 second')
  `, [player, `Mutation ${index}`, index + 1, index]);
}

const limited = await db.query("select gem_name,rarity from get_rare_roll_chat_history(5)");
const bases = limited.rows.filter((row) => Number(row.rarity) >= 100000000 && /^(Base|Linked|Orphan)/.test(row.gem_name));
const mutations = limited.rows.filter((row) => row.gem_name.startsWith("Mutation"));
assert.equal(bases.length, 5);
assert.equal(mutations.length, 5);
assert.deepEqual(bases.map((row) => row.gem_name).sort(), ["Base 1", "Base 2", "Base 3", "Base 4", "Base 5"]);
assert.deepEqual(mutations.map((row) => row.gem_name).sort(), ["Mutation 1", "Mutation 2", "Mutation 3", "Mutation 4", "Mutation 5"]);

await db.close();
console.log("Rare Roll durable details and per-category limits passed.");
