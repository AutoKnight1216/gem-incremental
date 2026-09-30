import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { feeAmount, listingFeeRate, marginalSellerTax } from "../auctions/market-fees.js";

const migration = readFileSync(new URL("../supabase/migrations/20260930094319_auction_market_redesign.sql", import.meta.url), "utf8");

const listingRates = new Map([[6, 0.005], [12, 0.0075], [24, 0.01], [48, 0.015], [72, 0.02]]);
for (const [hours, rate] of listingRates) {
  assert.equal(listingFeeRate(hours), rate);
  assert.equal(feeAmount(100, rate), 100 * rate);
}
assert.equal(listingFeeRate(1), null);

const r = 100;
const expected = new Map([
  [2 * r, 4],
  [5 * r, 13],
  [10 * r, 33],
  [25 * r, 108],
  [50 * r, 295.5]
]);
for (const [price, tax] of expected) assert.equal(marginalSellerTax(price, r), tax);
assert.equal(marginalSellerTax(50 * r + 1, r), 295.6);
assert.equal(marginalSellerTax(2 * r + 1, r), 4.03);
assert.equal(marginalSellerTax(5 * r + 1, r), 13.04);
assert.equal(marginalSellerTax(10 * r + 1, r), 33.05);
assert.equal(marginalSellerTax(25 * r + 1, r), 108.075);

assert.match(migration, /least\(p_price, 2 \* p_reference_value\) \* 0\.02/);
assert.match(migration, /greatest\(p_price - 50 \* p_reference_value, 0\) \* 0\.10/);
assert.match(migration, /v_proceeds := v_a\.current_bid::numeric - v_tax/);
assert.doesNotMatch(migration, /player_market_fee_rate\(v_a\.seller_id/);

console.log("Auction listing fee and marginal seller tax checks passed.");
