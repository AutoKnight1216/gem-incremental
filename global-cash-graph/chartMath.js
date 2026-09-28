export function chartBounds(values) {
  let min = Math.min(...values), max = Math.max(...values);
  // At very large balances, +/- 1 can round back to the original number.
  const padding = Math.max((max - min) * 0.08, Math.abs(max) * 0.01, Math.abs(min) * 0.01, 1);
  return [min - padding, max + padding];
}

export function niceTicks(min, max, count = 4) {
  const span = max - min;
  if (!Number.isFinite(span) || span <= 0) return [];
  const step0 = span / count;
  const mag = 10 ** Math.floor(Math.log10(step0));
  const norm = step0 / mag;
  const step = (norm >= 5 ? 5 : norm >= 2 ? 2 : 1) * mag;
  const start = Math.ceil(min / step) * step;
  const ticks = [];
  // Bound iteration; repeated addition can otherwise stall at float precision.
  for (let i = 0; i < 32; i++) {
    const value = start + i * step;
    if (!Number.isFinite(value) || value > max + step * 0.001) break;
    if (!ticks.length || value > ticks[ticks.length - 1]) ticks.push(value);
  }
  return ticks;
}

export function largeMoney(value, digits = 1) {
  const n = Number(value);
  if (Math.abs(n) >= 1e21) return "$" + n.toExponential(digits);
  if (Math.abs(n) >= 1e18) return "$" + (n / 1e18).toFixed(digits) + "Qi";
  if (Math.abs(n) >= 1e15) return "$" + (n / 1e15).toFixed(digits) + "Qa";
  return null;
}
// Keep missing history blank instead of stretching fresh samples across a range.
export function historyWindow(rows, hours, now = Date.now()) {
  const first = rows[0]?.t ?? now;
  const end = Math.max(now, rows.at(-1)?.t ?? now);
  const start = hours === 100000 ? Math.min(first, end - 600000) : end - hours * 3600000;
  return { start, end, partial: first > start + 600000 };
}

// Yahoo-style autoscale: bounds hug the data, padded 8% of its span. The
// floors keep a flat series visible, and the relative one stays far above
// float precision at very large balances.
export function fitBounds(values, relativeFloor = 1e-6, absoluteFloor = 0.5) {
  const min = Math.min(...values);
  const max = Math.max(...values);
  const magnitude = Math.max(Math.abs(max), Math.abs(min));
  const padding = Math.max((max - min) * 0.08, magnitude * relativeFloor, absoluteFloor);
  return [min - padding, max + padding];
}

// Bounds for a log-scaled axis, padded in log space. Non-positive values
// can't sit on a log axis, so they're ignored here and clamped when drawn.
export function logBounds(values) {
  const positive = values.filter((value) => value > 0);
  if (!positive.length) return [1, 10];
  const low = Math.log10(Math.min(...positive));
  const high = Math.log10(Math.max(...positive));
  const padding = Math.max((high - low) * 0.08, 1e-7);
  return [10 ** (low - padding), 10 ** (high + padding)];
}

// Ticks for a log-scaled axis: whole decades (plus 2x / 5x steps when there
// are only a few) across wide spans, ordinary nice ticks across narrow ones.
export function logTicks(min, max, count = 4) {
  if (!(min > 0) || !(max > min)) return [];
  const lowExponent = Math.floor(Math.log10(min));
  const highExponent = Math.ceil(Math.log10(max));
  if (highExponent - lowExponent < 2) return niceTicks(min, max, count);
  const steps = highExponent - lowExponent <= 3 ? [1, 2, 5] : [1];
  const ticks = [];
  for (let exponent = lowExponent; exponent <= highExponent && ticks.length < 32; exponent++) {
    for (const step of steps) {
      const value = step * 10 ** exponent;
      if (value >= min && value <= max) ticks.push(value);
    }
  }
  return ticks;
}

// Keep at most one sample per horizontal pixel (the latest in each column)
// so hours of one-second ticks still draw quickly. Returns kept indexes.
export function decimateByPixel(xs) {
  const kept = [];
  let column = null;
  for (let index = 0; index < xs.length; index++) {
    const nextColumn = Math.round(xs[index]);
    if (nextColumn === column) {
      kept[kept.length - 1] = index;
    } else {
      kept.push(index);
      column = nextColumn;
    }
  }
  return kept;
}

// Live quotes poll on a jittered 0.7-1s cadence so viewers don't all hit
// the server in lockstep.
export function nextTickDelay(random = Math.random) {
  return 700 + Math.round(random() * 300);
}
