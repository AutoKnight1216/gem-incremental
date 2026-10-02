import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const migration = read("../supabase/migrations/20261002082056_weekly_gem_catalogue_300.sql");
const roll = read("../supabase/functions/roll/index.ts");
const index = read("../gem-index/index.js");

assert.match(migration, /'300'[\s\S]*?"catalogueOrder":300/);
assert.match(migration, /'Ore\+'[\s\S]*?automaticConsumptionProtected/);
assert.match(migration, /'i', 1, 1, 0[\s\S]*?"displayRarity":-1[\s\S]*?"normalRng":false/);
assert.match(migration, /where player_id = v_player_id and gem_name = 'π'[\s\S]*?gem_name = 'e'/);
assert.match(migration, /locked, museum_locked, luck_at_roll[\s\S]*?true, false, 1/);
assert.match(migration, /primary key \(player_id, puzzle_id\)/);
assert.match(migration, /p_source = 'auto' and public\.gem_automatic_consumption_protected/);
assert.match(migration, /v_protected boolean := coalesce[\s\S]*?automatic-consumption-protection/);

assert.match(roll, /protectedFromAutomaticConsumption = specimen\.automatic_consumption_protected === true/);
assert.match(roll, /gem\.metadata\?\.automaticConsumptionProtected !== true[\s\S]*?deepcoreContext/);
assert.match(roll, /metadata\?\.sourceExclusive !== true/);

assert.match(index, /gemSearch\.value\.trim\(\) === "-1"/);
assert.match(index, /Not in the reals\./);
assert.match(index, /\?² = −1/);
assert.match(index, /claim_anomalous_i/);
assert.match(index, /displayRarity/);
assert.match(index, /puzzleClue/);

console.log("Weekly gems UI/roll checks passed.");
