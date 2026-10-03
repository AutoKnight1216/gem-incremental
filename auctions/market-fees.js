const LISTING_FEE_RATES = new Map([
  [6, 0.005],
  [12, 0.0075],
  [24, 0.01],
  [48, 0.015],
  [72, 0.02]
]);

export function listingFeeRate(hours) {
  return LISTING_FEE_RATES.get(Number(hours)) ?? null;
}

export function feeAmount(referenceValue, rate) {
  return Math.max(0, Number(referenceValue) || 0) * Math.max(0, Number(rate) || 0);
}

export function marginalSellerTax(price, referenceValue) {
  const p = Math.max(0, Number(price) || 0);
  const r = Math.max(0, Number(referenceValue) || 0);
  if (!(r > 0)) return 0;
  return (
    Math.min(p, 2 * r) * 0.02
    + Math.max(Math.min(p, 5 * r) - 2 * r, 0) * 0.03
    + Math.max(Math.min(p, 10 * r) - 5 * r, 0) * 0.04
    + Math.max(Math.min(p, 25 * r) - 10 * r, 0) * 0.05
    + Math.max(Math.min(p, 50 * r) - 25 * r, 0) * 0.075
    + Math.max(p - 50 * r, 0) * 0.10
  );
}
