import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { globalRecap, personalRecap, shareSummary, summarySvg } from "../recap/month-2/render.js";
import { gemTimeAvailable } from "../supabase/functions/roll/availabilityRules.ts";

const fixture = {
  status: "final",
  global: {
    totals: { rolls: 200, earned: 2000, burned: 200, players: 2, active_players: 2, new_players: 1, median_rolls: 100, rollers_1k: 0, rollers_10k: 0, rollers_100k: 0 },
    monthOne: { totals: { rolls: 100, earned: 1000, burned: 100, players: 1, median_rolls: 100, rollers_1k: 0, rollers_10k: 0, rollers_100k: 0 }, records: {}, minigameRuns: 1, minigamePlayers: 1 },
    records: { displayed: { gem: "Duolite", rarity: 2020026, score: 2020026, luck: 2, at: "2026-10-07T16:01:00Z" }, raw: { gem: "Duolite", rarity: 2020026, rawRarity: 1010013, score: 1010013, luck: 2 }, value: { gem: "Duolite", rarity: 2020026, value: 409252, score: 409252, luck: 2 }, weight: { gem: "Duolite", rarity: 2020026, weight: 202, score: 202 }, mutations: null, combo: null },
    topRollers: [{ username: "One", rolls: 150 }], topTenShare: 100, richest: { username: "One", money: 50 }, minigameRuns: 2, minigamePlayers: 1, minigames: []
  },
  personal: { username: "One", joined: "2026-08-08", joinNumber: 1, newPlayer: false, monthTwoRolls: 150, lifetimeRolls: 250, monthTwoEarned: 1500, lifetimeEarned: 2500, monthTwoBurned: 150, lifetimeBurned: 250, population: 2, rollRank: 1, earningsRank: 1, rollTopPercent: 50, earningsTopPercent: 50, rollShare: 75, monthOne: { rolls: 100, rollRank: 2, earningsRank: 2, records: {} }, highestDisplayed: { gem: "Duolite", rarity: 2020026, score: 2020026, luck: 2 }, rawRare: { gem: "Duolite", rarity: 2020026, rawRarity: 1010013, score: 1010013, luck: 2 }, records: {}, minigames: [] }
};

assert.match(globalRecap(fixture), /One Month Later/);
assert.match(globalRecap(fixture), /Highest Displayed Rarity/);
assert.match(globalRecap(fixture), /Best Raw Rare Roll/);
assert.match(globalRecap(fixture), /Heaviest Recorded Roll/);
assert.match(personalRecap(fixture), /#2/);
assert.match(personalRecap(fixture), /#1/);
assert.match(shareSummary(fixture), /MONTH TWO/);
assert.match(summarySvg(fixture), /xmlns="http:\/\/www\.w3\.org\/2000\/svg"/);
const hostile = structuredClone(fixture);
hostile.personal.username = '<script>alert("x")</script>';
assert.ok(!personalRecap(hostile).includes("<script>"));

const intro = await fs.readFile(new URL("../src/ui/monthTwoAnniversary.js", import.meta.url), "utf8");
assert.match(intro, /get_month_two_anniversary_intro/);
assert.match(intro, /Something is different today/);
assert.doesNotMatch(intro, /Duolite/);
const shell = await fs.readFile(new URL("../src/ui/shell.js", import.meta.url), "utf8");
assert.match(shell, /mountMonthTwoAnniversary/);
const migration = await fs.readFile(new URL("../supabase/migrations/20260927052133_reusable_recap_month_two_anniversary.sql", import.meta.url), "utf8");
assert.match(migration, /players\.total_rolls|total_rolls/);
assert.doesNotMatch(migration, /equipment_genuine_rolls/);
const duoliteWindow = { starts_at: "2026-10-07T16:00:00Z", ends_at: "2026-10-08T16:00:00Z", availability_mode: "date_range" };
assert.equal(gemTimeAvailable(duoliteWindow, new Date("2026-10-07T15:59:59.999Z")), false);
assert.equal(gemTimeAvailable(duoliteWindow, new Date("2026-10-07T16:00:00.000Z")), true);
assert.equal(gemTimeAvailable(duoliteWindow, new Date("2026-10-08T15:59:59.999Z")), true);
assert.equal(gemTimeAvailable(duoliteWindow, new Date("2026-10-08T16:00:00.000Z")), false);
console.log("Month Two client: comparisons, records, safe sharing, intro copy and total-roll source passed.");
