import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  compareInventoryEffectiveRarity,
  inventoryEffectiveRarity,
} from "../src/logic/inventorySort.js";

const gems = [
  { id: 1, rarity: 1_000_000, effective_rarity: 1_000_000, created_at: "2026-01-03" },
  { id: 2, rarity: 100, effective_rarity: 10_000_000, created_at: "2026-01-01" },
  { id: 3, rarity: 10_000_000, effective_rarity: null, created_at: "2026-01-02" },
  { id: 4, rarity: 9_000_000, effective_rarity: 10_000_000, created_at: "2026-01-04" },
];

assert.equal(inventoryEffectiveRarity(gems[2]), 10_000_000);
assert.deepEqual(
  [...gems].sort(compareInventoryEffectiveRarity).map((gem) => gem.id),
  [3, 4, 2, 1],
);

const page = readFileSync(new URL("../inventory/index.html", import.meta.url), "utf8");
const client = readFileSync(new URL("../inventory/inventory.js", import.meta.url), "utf8");
const backend = readFileSync(new URL("../src/backend/cloudInventory.js", import.meta.url), "utf8");
assert.match(page, /option value="effectiveRarity">Highest effective rarity<\/option>/);
assert.match(client, /effectiveRarity: compareInventoryEffectiveRarity/);
assert.match(backend, /\beffective_rarity,/);

console.log("Inventory effective-rarity sorting uses the authoritative stored denominator.");
