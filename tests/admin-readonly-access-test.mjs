import assert from "node:assert/strict";
import fs from "node:fs";

const read = (path) => fs.readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

const edge = read("supabase/functions/admin/index.ts");
const admin = read("admin/admin.js");
const html = read("admin/index.html");
const migration = read("supabase/migrations/20261003053148_admin_panel_readonly_access.sql");

assert.match(edge, /OWNER_ADMIN_ID = "004d883f-edbc-4610-b5e3-9068a0de0ca2"/);
assert.match(edge, /const READ_ONLY_ACTIONS = new Set/);
for (const action of ["search", "inspect", "audit", "analytics", "market_fee_analytics", "museum_analytics"]) {
  assert.match(edge, new RegExp(`"${action}"`));
}
assert.match(edge, /adminId !== OWNER_ADMIN_ID && !READ_ONLY_ACTIONS\.has\(action\)/);
assert.match(edge, /error: "admin_read_only"/);
assert.match(edge, /canWrite, access: canWrite \? "owner" : "read_only"/);

assert.match(migration, /bddf7c33-e69c-44e5-98db-3bcc10e582ba/);
assert.match(migration, /657b756e-c21e-40ab-b2b5-b13403f89039/);
assert.match(migration, /where exists \(select 1 from auth\.users/);

assert.doesNotMatch(html, /id="shareholdersPanel"/);
assert.doesNotMatch(html, /data-admin-tab="(?:equipment|pets|workbench|limited-events)"/);
assert.match(admin, /if \(!canWriteAdmin\) return;/);
assert.match(admin, /button\.hidden = true/);
assert.match(admin, /playerPanel\.querySelectorAll\("input, select, textarea, button\[data-action\]"\)/);

console.log("admin-readonly-access-test passed");
