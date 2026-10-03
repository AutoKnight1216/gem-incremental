import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const db = new PGlite();
const migration = fs.readFileSync(
  new URL("../supabase/migrations/20261003053148_admin_panel_readonly_access.sql", import.meta.url),
  "utf8"
);

const owner = "004d883f-edbc-4610-b5e3-9068a0de0ca2";
const formerOwner = "38d5e8ce-18af-46d3-aa9e-6e601e75dd78";
const existingAdmin = "316c668e-1ab3-4e5f-bad0-8cd964a41440";
const flame = "bddf7c33-e69c-44e5-98db-3bcc10e582ba";
const kei = "657b756e-c21e-40ab-b2b5-b13403f89039";

await db.exec(`
  create role anon;
  create role authenticated;
  create schema auth;
  create table auth.users (id uuid primary key);
  insert into auth.users(id) values
    ('${owner}'), ('${formerOwner}'), ('${existingAdmin}'), ('${flame}'), ('${kei}');

  create function auth.uid() returns uuid language sql stable as
  $$ select '${formerOwner}'::uuid $$;

  create table public.admins (
    user_id uuid primary key references auth.users(id) on delete cascade,
    note text,
    created_at timestamptz not null default now()
  );
  alter table public.admins enable row level security;
  insert into public.admins(user_id, note) values
    ('${owner}', 'owner'), ('${existingAdmin}', 'existing admin');

  create function public.legacy_admin_probe() returns boolean
  language sql stable as
  $$ select auth.uid() = '${formerOwner}'::uuid $$;
`);

await db.exec(migration);

const writers = await db.query("select user_id::text as user_id from public.admins order by user_id");
assert.deepEqual(writers.rows, [{ user_id: owner }]);

const viewers = await db.query("select user_id::text as user_id from public.admin_viewers order by user_id");
assert.deepEqual(viewers.rows.map((row) => row.user_id), [existingAdmin, kei, flame].sort());

const functionDefinition = await db.query(
  "select pg_get_functiondef('public.legacy_admin_probe()'::regprocedure) as definition"
);
assert.match(functionDefinition.rows[0].definition, new RegExp(owner));
assert.doesNotMatch(functionDefinition.rows[0].definition, new RegExp(formerOwner));

console.log("admin-readonly-access-database-test passed");
