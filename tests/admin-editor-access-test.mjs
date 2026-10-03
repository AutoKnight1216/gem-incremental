import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const migration = fs.readFileSync(
  new URL("../supabase/migrations/20261003120000_sixseven67_admin_edit_access.sql", import.meta.url),
  "utf8"
);
const edge = fs.readFileSync(
  new URL("../supabase/functions/admin/index.ts", import.meta.url),
  "utf8"
);

const target = "11111111-1111-4111-8111-111111111111";
const other = "22222222-2222-4222-8222-222222222222";
const db = new PGlite();
await db.exec(`
  create role anon;
  create role authenticated;
  create schema auth;
  create table auth.users (id uuid primary key);
  create table public.players (id uuid primary key, username text);
  create table public.admins (user_id uuid primary key references auth.users(id), note text);
  create table public.admin_viewers (user_id uuid primary key references auth.users(id), note text);
  insert into auth.users (id) values ('${target}'), ('${other}');
  insert into public.players (id, username) values
    ('${target}', 'SixSeven67'), ('${other}', 'SomeoneElse');
  insert into public.admin_viewers (user_id) values ('${target}'), ('${other}');
`);

await db.exec(migration);
await db.exec(migration);
const writers = await db.query("select user_id::text as id from public.admins");
assert.deepEqual(writers.rows, [{ id: target }]);
const viewers = await db.query("select user_id::text as id from public.admin_viewers");
assert.deepEqual(viewers.rows, [{ id: other }]);

assert.match(edge, /if \(data\?\.user_id === id\) return \{ isAdmin: true, canWrite: true \}/);
assert.match(edge, /const \{ isAdmin, canWrite \} = await adminAccess\(ctx, adminId\)/);
assert.match(edge, /const \{ isAdmin, canWrite: canWriteAdmin \} = await adminAccess\(ctx, adminId\)/);
assert.doesNotMatch(edge, /const canWriteAdmin = adminId === OWNER_ADMIN_ID/);

console.log("admin-editor-access-test passed");
