import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const migration = read("supabase/migrations/20261003033244_add_game_maintenance_windows.sql");
const adminEdge = read("supabase/functions/admin/index.ts");
const rollEdge = read("supabase/functions/roll/index.ts");
const adminHtml = read("admin/index.html");
const adminUi = read("admin/admin.js");
const maintenanceUi = read("src/ui/maintenanceMode.js");

const db = new PGlite();
await db.exec(`
  create role anon;
  create role authenticated;
  create role service_role;
  create schema auth;
  create table auth.users (id uuid primary key);
`);
await db.exec(migration);

const initial = (await db.query("select public.get_game_maintenance_status() status")).rows[0].status;
assert.equal(initial.phase, "inactive");

await assert.rejects(
  db.exec("update public.game_maintenance set starts_at=now(), ends_at=now()+interval '30 seconds' where id='global'"),
  /game_maintenance_minimum_duration/
);
await db.exec("update public.game_maintenance set starts_at=now()-interval '1 minute', ends_at=now()+interval '2 minutes' where id='global'");
const active = (await db.query("select public.get_game_maintenance_status() status")).rows[0].status;
assert.equal(active.phase, "active");

await db.exec("set role anon");
assert.equal((await db.query("select count(*)::int count from public.game_maintenance")).rows[0].count, 1);
await assert.rejects(
  db.exec("update public.game_maintenance set message='not allowed' where id='global'"),
  /permission denied/
);
await db.exec("reset role");

assert.match(adminEdge, /action === "maintenance_schedule"/);
assert.match(adminEdge, /durationMinutes < 1/);
assert.match(adminEdge, /action === "maintenance_end"/);
assert.match(adminEdge, /game_shutdown_scheduled/);
assert.match(rollEdge, /activeMaintenanceWindow/);
assert.match(rollEdge, /now - maintenanceCache\.checkedAt >= 5_000/);
assert.ok(
  rollEdge.indexOf("const maintenance = await activeMaintenanceWindow(ctx)") <
    rollEdge.indexOf("const rateLimitResponse = await enforceRollRequestRateLimit(ctx)"),
  "maintenance must reject before roll processing begins"
);
assert.match(rollEdge, /error: "game_maintenance"/);

assert.match(adminHtml, /id="maintenancePanel"/);
assert.match(adminHtml, /id="maintenanceCustomDuration"[^>]*min="1"/);
assert.match(adminHtml, /id="maintenanceEnd"/);
assert.match(adminUi, /Enable game now/);
assert.match(maintenanceUi, /Game shutting down for an update/);
assert.match(maintenanceUi, /Game update in progress/);
assert.match(maintenanceUi, /setInterval\(refresh, POLL_MS\)/);

console.log("game-maintenance-shutdown-test passed");
