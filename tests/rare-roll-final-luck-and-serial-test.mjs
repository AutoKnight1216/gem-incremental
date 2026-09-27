import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const migration = readFileSync(
  new URL("../supabase/migrations/20260927090638_sync_rare_roll_final_luck_and_serial.sql", import.meta.url),
  "utf8"
);

assert.match(migration, /g\.luck_at_roll/);
assert.match(migration, /new\.raw_luck := coalesce\(v_luck_at_roll, new\.raw_luck\)/);
assert.match(migration, /new\.serial_number := coalesce\(v_serial_number, new\.serial_number\)/);
assert.match(migration, /g\.roll_number = h\.roll_number/);

const db = new PGlite();
await db.exec(`
  create table inventory_gems(
    id bigint generated always as identity primary key,
    player_id uuid not null,
    gem_name text not null,
    roll_number bigint,
    luck_at_roll numeric,
    serial_number bigint,
    created_at timestamptz not null default now()
  );
  create table best_roll_history(
    id bigint generated always as identity primary key,
    player_id uuid not null,
    gem_name text not null,
    roll_number bigint,
    raw_luck numeric not null,
    serial_number bigint,
    created_at timestamptz not null default now()
  );
  create table rare_roll_chat_events(
    id bigint generated always as identity primary key,
    source_type text not null,
    source_id bigint,
    luck_at_roll numeric,
    serial_number bigint
  );
`);

const player = "00000000-0000-0000-0000-000000000001";
await db.query(`
  insert into inventory_gems(
    player_id,gem_name,roll_number,luck_at_roll,serial_number
  ) values($1,'the last gem',724000,1003493.4,3)
`, [player]);
const history = await db.query(`
  insert into best_roll_history(
    player_id,gem_name,roll_number,raw_luck,serial_number
  ) values($1,'the last gem',723999,34.8,null)
  returning id
`, [player]);
await db.query(`
  insert into rare_roll_chat_events(
    source_type,source_id,luck_at_roll,serial_number
  ) values('history',$1,34.8,null)
`, [history.rows[0].id]);

await db.exec(migration);

const repaired = await db.query(`
  select h.raw_luck,h.serial_number,e.luck_at_roll as event_luck,
    e.serial_number as event_serial
  from best_roll_history h
  join rare_roll_chat_events e on e.source_id = h.id
`);
assert.deepEqual(repaired.rows.map((row) => [
  Number(row.raw_luck),
  Number(row.serial_number),
  Number(row.event_luck),
  Number(row.event_serial)
]), [[1003493.4, 3, 1003493.4, 3]]);

// Future history inserts inherit both authoritative specimen fields before
// the Rare Rolls persistence trigger observes NEW.
await db.query(`
  insert into inventory_gems(
    player_id,gem_name,roll_number,luck_at_roll,serial_number
  ) values($1,'Future Base',724001,555555.25,9)
`, [player]);
const future = await db.query(`
  insert into best_roll_history(
    player_id,gem_name,roll_number,raw_luck,serial_number
  ) values($1,'Future Base',724001,12.5,null)
  returning raw_luck,serial_number
`, [player]);
assert.deepEqual([
  Number(future.rows[0].raw_luck),
  Number(future.rows[0].serial_number)
], [555555.25, 9]);

await db.close();
console.log("Rare Roll final Luck and serial synchronization passed.");
