export const BATCH_ROLL_OPTIONS = [
  { size: 1, label: "×1", baseCooldownSeconds: 2.5, requirement: "Available by default" },
  { size: 2, label: "×2", baseCooldownSeconds: 5, requirement: "Available by default" },
  { size: 3, label: "×3", baseCooldownSeconds: 7.5, requirement: "50,000 lifetime rolls" },
  { size: 4, label: "×4", baseCooldownSeconds: 10, requirement: "200,000 lifetime rolls + Celestial Pickaxe" },
  { size: 5, label: "×5", baseCooldownSeconds: 12.5, requirement: "500,000 lifetime rolls + 3 specialist Pickaxes" }
];

// These are the built-in, non-Toy horizontal recipes labelled “Specialist”
// on the Crafting page. Keep this list aligned with the backend gate.
export const BATCH_SPECIALIST_PICKAXE_IDS = Object.freeze([
  "fortune-pickaxe",
  "all-in-pickaxe",
  "empyrean-pickaxe",
  "eternity-pickaxe",
  "tectonic-pickaxe",
  "the-accelerator",
  "the-resonator",
  "the-excavator",
  "bedrock-pickaxe",
  "supersizer-pickaxe"
]);

const BATCH_SPECIALIST_PICKAXES = new Set(BATCH_SPECIALIST_PICKAXE_IDS);

export function normalizeUiBatchSize(value) {
  const size = Number(value);
  return Number.isSafeInteger(size) && size >= 1 && size <= 100 ? size : 1;
}

export function getEquipmentRollBulk(access = {}) {
  return Math.max(0, Math.floor(Number(access.rollBulk ?? 0) || 0));
}

export function getMaximumBatchSize(access = {}) {
  return Math.min(100, 5 + getEquipmentRollBulk(access));
}

export function countOwnedBatchSpecialistPickaxes(equipment = []) {
  return new Set(
    (Array.isArray(equipment) ? equipment : [])
      .map((item) => item?.equipment_id)
      .filter((id) => BATCH_SPECIALIST_PICKAXES.has(id))
  ).size;
}

export function isBatchSizeUnlocked(size, { totalRolls = 0, hasCelestialPickaxe = false, specialistPickaxes = 0, rollBulk = 0 } = {}) {
  const normalized = normalizeUiBatchSize(size);
  if (normalized <= 2) return true;
  if (normalized === 3) return Number(totalRolls) >= 50_000;
  if (normalized === 4) return Number(totalRolls) >= 200_000 && hasCelestialPickaxe === true;
  return Number(totalRolls) >= 500_000 && Number(specialistPickaxes) >= 3 && normalized <= getMaximumBatchSize({ rollBulk });
}

export function batchRollResults(response) {
  if (Array.isArray(response?.results)) return response.results;
  return response ? [response] : [];
}

export function batchCooldown(response) {
  return response?.cooldown ?? batchRollResults(response).at(-1)?.cooldown ?? null;
}

export function renderBatchOptions(access = {}) {
  const max = getMaximumBatchSize(access);
  const options = [];
  for (let size = 1; size <= max; size++) {
    const unlocked = isBatchSizeUnlocked(size, access);
    let suffix = "base";
    if (size === 1) suffix = "base";
    else if (size === 2) suffix = "base";
    else if (size === 3) suffix = "50,000 lifetime rolls";
    else if (size === 4) suffix = "200,000 lifetime rolls + Celestial Pickaxe";
    else if (size === 5) suffix = "500,000 lifetime rolls + 3 specialist Pickaxes";
    else suffix = `Roll Bulk +${size - 5}`;
    options.push(`<option value="${size}" ${unlocked ? "" : "disabled"}>×${size} · ${suffix}</option>`);
  }
  return options.join("");
}
