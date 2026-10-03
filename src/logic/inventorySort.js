export function inventoryEffectiveRarity(gem) {
  const stored = Number(gem?.effective_rarity ?? gem?.effectiveRarity);
  if (Number.isFinite(stored) && stored > 0) return stored;

  const base = Number(gem?.rarity);
  return Number.isFinite(base) && base > 0 ? base : 0;
}

export function compareInventoryEffectiveRarity(a, b) {
  return inventoryEffectiveRarity(b) - inventoryEffectiveRarity(a)
    || Number(b?.rarity ?? 0) - Number(a?.rarity ?? 0)
    || new Date(b?.created_at ?? 0) - new Date(a?.created_at ?? 0)
    || Number(b?.id ?? 0) - Number(a?.id ?? 0);
}
