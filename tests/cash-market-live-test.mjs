import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  fitBounds,
  logBounds,
  logTicks,
  decimateByPixel,
  nextTickDelay
} from "../global-cash-graph/chartMath.js";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

// ── Live tick: cached server-side so viewer count doesn't multiply load ──
const migration = read("supabase/migrations/20260928120000_cash_market_live_tick.sql");
assert.match(migration, /create table if not exists public\.cash_market_tick/);
assert.match(migration, /check \(id = 1\)/);
assert.match(migration, /alter table public\.cash_market_tick enable row level security/);
assert.match(migration, /create or replace function public\.get_cash_market_tick\(\)/);
assert.match(migration, /interval '1 second'/);
assert.match(migration, /pg_try_advisory_xact_lock/);
assert.match(migration, /system_account_exclusions/);
assert.match(migration, /grant execute on function public\.get_cash_market_tick\(\) to anon, authenticated/);

// ── Client: jittered 0.7-1s ticks, fallback, pause when hidden ──
const graph = read("global-cash-graph/graph.js");
assert.equal((graph.match(/supabase\.rpc\("get_cash_market_tick"\)/g) ?? []).length, 1);
assert.match(graph, /supabase\.rpc\("get_global_cash_feed"\)/);
assert.match(graph, /FALLBACK_TICK_MS = 5000/);
assert.match(graph, /nextTickDelay\(\)/);
assert.match(graph, /if \(document\.hidden \|\| tickTimer \|\| tickInFlight\) return;/);
assert.match(graph, /decimateByPixel\(xs\)/);
assert.match(graph, /flashPrice\(/);

for (let sample = 0; sample <= 1; sample += 0.1) {
  const delay = nextTickDelay(() => sample);
  assert.ok(delay >= 700 && delay <= 1000, `tick delay ${delay} outside 0.7-1s`);
}

// ── Changeable scale: linear / log / percent, remembered per viewer ──
const page = read("global-cash-graph/index.html");
for (const scale of ["linear", "log", "percent"]) {
  assert.match(page, new RegExp(`data-scale="${scale}"`));
}
for (const range of ["5m", "15m", "1h", "6h", "1d", "5d", "max"]) {
  assert.match(page, new RegExp(`data-range="${range}"`));
  assert.match(graph, new RegExp(`"${range}": \{ hours:`));
}
assert.match(graph, /const SCALES = \["linear", "log", "percent"\]/);
assert.match(graph, /gemIncremental\.cashMarket\.view/);
assert.match(page, /data-stat="prevClose"/);
assert.match(page, /data-asof/);

const css = read("global-cash-graph/graph.css");
assert.match(css, /\.market__price--flash-up/);
assert.match(css, /\.market__stats \{/);

// ── Scale math ──
for (const values of [[0, 0], [100, 100], [866770690274325000, 866770690274325000], [5e9, 866770690274325000]]) {
  const [low, high] = fitBounds(values);
  assert.ok(Number.isFinite(low) && Number.isFinite(high) && high > low);
  for (const value of values) assert.ok(low < value && value < high);
  // Tight on a flat series (unlike chartBounds' 1% pad), so live moves show.
  if (values[0] === values[1]) assert.ok(high - low <= Math.max(1, Math.abs(values[0]) * 2.1e-6));
}
const [logLow, logHigh] = logBounds([0, 1e6, 1e12]);
assert.ok(logLow > 0 && logLow < 1e6 && logHigh > 1e12);
assert.deepEqual(logBounds([0, -5]), [1, 10]);
const decades = logTicks(1e3, 1e12);
assert.ok(decades.includes(1e6) && decades.every((tick) => tick >= 1e3 && tick <= 1e12));
assert.ok(logTicks(100, 180).length > 0);
assert.deepEqual(logTicks(0, 10), []);
assert.deepEqual(decimateByPixel([0, 0.2, 0.4, 1, 1.1, 5]), [2, 4, 5]);

console.log("Cash Market live checks passed.");
