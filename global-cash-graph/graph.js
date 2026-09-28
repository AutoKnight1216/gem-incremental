import { supabase } from "../src/backend/supabase.js";
import { burnMoney, loadFurnaceState } from "../src/backend/cloudFurnace.js";
import { confirmDialog } from "../src/ui/dialog.js";
import {
  fitBounds,
  logBounds,
  logTicks,
  niceTicks,
  largeMoney,
  historyWindow,
  decimateByPixel,
  nextTickDelay
} from "./chartMath.js";

// =========================================================
// CASH MARKET
//
// A stock-quote view of the whole economy, styled after a Yahoo Finance
// quote page. Three series (global cash = lifetime earnings, player cash =
// current wallets, bank deposits) are drawn as a line + gradient area over a
// chosen time range, against a dashed "open" baseline.
//
// Two data sources feed it:
//   • history — 10-minute snapshots (get_global_cash_history), refreshed
//     every minute, for the longer ranges.
//   • ticks   — a live quote (get_cash_market_tick) polled every 0.7-1s,
//     cached server-side so viewers never cost more than one recompute a
//     second. Ticks extend the line past the last snapshot and fill the
//     short 5m / 15m ranges.
//
// The y-axis scale can be linear, logarithmic, or percent change from the
// start of the range.
//
// The SVG is drawn in real pixel coordinates (viewBox tracks the
// container size) so stroke widths stay uniform at any width.
// =========================================================

const SVGNS = "http://www.w3.org/2000/svg";
const HISTORY_POLL_MS = 60000;
const FALLBACK_TICK_MS = 5000;
const TICK_BUFFER_MS = 2 * 3600000;
const VIEW_STORAGE_KEY = "gemIncremental.cashMarket.view";

const chart = document.querySelector("[data-chart]");
const wrap = chart.parentElement;
const tooltip = document.querySelector("[data-tooltip]");
const statusEl = document.querySelector("[data-status]");
const priceEl = document.querySelector("[data-price]");
const changeEl = document.querySelector("[data-change]");
const changeAbsEl = document.querySelector("[data-change-abs]");
const changePctEl = document.querySelector("[data-change-pct]");
const changeRangeEl = document.querySelector("[data-change-range]");
const asOfEl = document.querySelector("[data-asof]");
const metricNameEl = document.querySelector("[data-metric-name]");
const symbolEl = document.querySelector("[data-symbol]");
const metricButtons = [...document.querySelectorAll("[data-metric]")];
const rangeButtons = [...document.querySelectorAll("[data-range]")];
const scaleButtons = [...document.querySelectorAll("[data-scale]")];
const statEls = Object.fromEntries(
  [...document.querySelectorAll("[data-stat]")].map((node) => [node.dataset.stat, node])
);
const furnaceForm = document.querySelector("[data-furnace-form]");
const furnaceInput = document.querySelector("[data-furnace-amount]");
const furnaceLifetime = document.querySelector("[data-furnace-lifetime]");
const furnaceStatus = document.querySelector("[data-furnace-status]");
const furnaceLeaderboard = document.querySelector("[data-furnace-leaderboard]");

// Y-axis labels sit on the right, quote-page style.
const PAD = { left: 10, right: 92, top: 16, bottom: 26 };

const METRIC_LABELS = { lifetime: "Global cash", money: "Player cash", bank: "Bank deposits" };
const METRIC_SYMBOLS = { lifetime: "GLBL", money: "CASH", bank: "BANK" };

const RANGES = {
  "5m": { hours: 5 / 60, label: "past 5 minutes" },
  "15m": { hours: 0.25, label: "past 15 minutes" },
  "1h": { hours: 1, label: "past hour" },
  "6h": { hours: 6, label: "past 6 hours" },
  "1d": { hours: 24, label: "past 24 hours" },
  "5d": { hours: 120, label: "past 5 days" },
  "max": { hours: 100000, label: "all time" }
};

const SCALES = ["linear", "log", "percent"];

let metric = "lifetime";
let rangeId = "1d";
let scale = "linear";
let history = [];    // 10-minute snapshots: [{ t: ms, lifetime, money, bank }]
let ticks = [];      // live quotes since the page opened, same shape
let rows = [];       // what the chart currently shows (history + ticks, windowed)
let layout = null;   // last-drawn geometry, for hover mapping
let hoverX = null;   // pointer position in chart px, kept across live redraws
let historyTimer = null;
let tickTimer = null;
let tickInFlight = false;
let tickSource = "live";   // "live" (cached tick RPC) or "fallback" (older feed RPC)
let tickFailing = false;
let furnaceMoney = 0;
let furnaceBusy = false;
let requestId = 0;

// ---------------------------------------------------------
// FORMATTING
// ---------------------------------------------------------

const MONEY_UNITS = [
  [1e18, "Qi"],
  [1e15, "Qa"],
  [1e12, "T"],
  [1e9, "B"],
  [1e6, "M"],
  [1e3, "K"]
];

function compact(value) {
  const n = Number(value) || 0;
  const abs = Math.abs(n);
  const sign = n < 0 ? "-" : "";
  if (abs >= 1e15) return sign + largeMoney(abs, 2);
  if (abs >= 1e12) return sign + "$" + (abs / 1e12).toFixed(2) + "T";
  if (abs >= 1e9) return sign + "$" + (abs / 1e9).toFixed(2) + "B";
  if (abs >= 1e6) return sign + "$" + (abs / 1e6).toFixed(2) + "M";
  if (abs >= 1e3) return sign + "$" + (abs / 1e3).toFixed(1) + "K";
  return sign + "$" + Math.round(abs).toLocaleString("en-US");
}

function signedCompact(value) {
  const n = Number(value) || 0;
  return (n >= 0 ? "+" : "−") + compact(Math.abs(n));
}

function fullMoney(value) {
  return "$" + Number(value || 0).toLocaleString("en-US", {
    minimumFractionDigits: 2, maximumFractionDigits: 2
  });
}

function signedPercent(value, digits = 2) {
  const n = Number(value) || 0;
  return (n >= 0 ? "+" : "−") + Math.abs(n).toFixed(digits) + "%";
}

// Decimals needed so neighbouring ticks `step` apart read differently.
function digitsForStep(step, unit) {
  if (!(step > 0) || !(unit > 0)) return 0;
  return Math.min(5, Math.max(0, Math.ceil(-Math.log10(step / unit) - 1e-9)));
}

function axisMoney(value, step) {
  const n = Number(value) || 0;
  const abs = Math.abs(n);
  const sign = n < 0 ? "-" : "";
  if (abs >= 1e21) return sign + "$" + abs.toExponential(2);
  const [unit, suffix] = MONEY_UNITS.find(([size]) => abs >= size) ?? [1, ""];
  return sign + "$" + (abs / unit).toFixed(digitsForStep(step, unit)) + suffix;
}

function axisPercent(value, step) {
  return signedPercent(value, digitsForStep(step, 1));
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]
  ));
}

function friendlyBurnError(error) {
  const message = String(error?.message ?? "");
  if (message.includes("insufficient_money")) return "You don't have enough money to burn that amount.";
  if (message.includes("not_authenticated")) return "Sign in to use the Furnace.";
  if (message.includes("invalid_burn_amount")) return "Enter an amount of at least $0.01.";
  return "The Furnace didn't light. Please try again.";
}

async function refreshFurnace() {
  const { data, error } = await loadFurnaceState();
  if (error) { furnaceStatus.textContent = "Couldn't load Furnace data."; return; }
  furnaceMoney = data.money;
  furnaceLifetime.textContent = fullMoney(data.lifetimeMoneyBurned);
  furnaceInput.disabled = !data.authenticated;
  furnaceForm.querySelectorAll("button").forEach((button) => { button.disabled = !data.authenticated; });
  furnaceStatus.textContent = data.authenticated ? "" : "Sign in to burn money.";
  furnaceLeaderboard.innerHTML = data.leaderboard.length
    ? data.leaderboard.map((row) => `<li><span>${escapeHtml(row.username)}</span><strong>${fullMoney(row.lifetime_money_burned)}</strong></li>`).join("")
    : '<li class="furnace__empty">No money has been burned yet. Be the first.</li>';
}

async function requestBurn({ amount = null, burnAll = false }) {
  if (furnaceBusy) return;
  const requested = burnAll ? furnaceMoney : Number(amount);
  if (!Number.isFinite(requested) || requested <= 0) {
    furnaceStatus.textContent = "Enter an amount of at least $0.01.";
    furnaceInput.focus();
    return;
  }
  const choice = await confirmDialog({
    title: `Burn ${fullMoney(requested)}?`,
    body: "<p>This money will be permanently destroyed. This cannot be undone.</p>",
    confirmLabel: burnAll ? "Burn everything" : "Burn money",
    tone: "danger"
  });
  if (choice !== "confirm") return;
  furnaceBusy = true;
  furnaceForm.querySelectorAll("button, input").forEach((control) => { control.disabled = true; });
  furnaceStatus.textContent = "Burning…";
  const { data, error } = await burnMoney({ amount: requested, burnAll });
  furnaceBusy = false;
  if (error) {
    furnaceStatus.textContent = friendlyBurnError(error);
    await refreshFurnace();
    return;
  }
  furnaceMoney = Number(data.money ?? 0);
  furnaceInput.value = "";
  window.cashMarketShell?.setWallet(furnaceMoney);
  await Promise.all([refreshFurnace(), refresh(), pollTick()]);
  furnaceStatus.textContent = `${fullMoney(data.burned)} permanently burned.`;
}

function rangeHours() {
  return RANGES[rangeId].hours;
}

function timeLabel(ms) {
  const d = new Date(ms);
  const hours = rangeHours();
  if (hours <= 0.25) {
    return d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", second: "2-digit" });
  }
  if (hours <= 24) {
    return d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
  }
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

function tooltipTime(ms) {
  const options = { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" };
  if (rangeHours() <= 6) options.second = "2-digit";
  return new Date(ms).toLocaleString("en-US", options);
}

function el(name, attrs = {}) {
  const node = document.createElementNS(SVGNS, name);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  return node;
}

// ---------------------------------------------------------
// VIEW PREFERENCES (per viewer, best effort)
// ---------------------------------------------------------

function loadView() {
  try {
    const saved = JSON.parse(localStorage.getItem(VIEW_STORAGE_KEY) ?? "null");
    if (saved && METRIC_LABELS[saved.metric]) metric = saved.metric;
    if (saved && RANGES[saved.range]) rangeId = saved.range;
    if (saved && SCALES.includes(saved.scale)) scale = saved.scale;
  } catch (error) {
    /* storage unavailable — defaults apply */
  }
}

function saveView() {
  try {
    localStorage.setItem(VIEW_STORAGE_KEY, JSON.stringify({ metric, range: rangeId, scale }));
  } catch (error) {
    /* storage unavailable — the choice just isn't remembered */
  }
}

function markSelected(buttons, isSelected) {
  for (const button of buttons) {
    const selected = isSelected(button);
    button.classList.toggle("active", selected);
    button.setAttribute("aria-selected", String(selected));
  }
}

function syncControls() {
  markSelected(metricButtons, (button) => button.dataset.metric === metric);
  markSelected(rangeButtons, (button) => button.dataset.range === rangeId);
  markSelected(scaleButtons, (button) => button.dataset.scale === scale);
}

// ---------------------------------------------------------
// DATA
// ---------------------------------------------------------

async function fetchHistory(requestedHours) {
  const { data, error } = await supabase.rpc("get_global_cash_history", { p_hours: requestedHours });
  if (error) throw error;
  const list = Array.isArray(data) ? data : [];
  return list
    .map((r) => ({
      t: new Date(r.at).getTime(),
      lifetime: Number(r.lifetime) || 0,
      money: Number(r.money) || 0,
      bank: Number(r.bank) || 0
    }))
    .filter((r) => Number.isFinite(r.t))
    .sort((a, b) => a.t - b.t);
}

function isMissingFunction(error) {
  const message = String(error?.message ?? "");
  return error?.code === "PGRST202"
    || error?.code === "42883"
    || /could not find the function/i.test(message);
}

// One live quote. Falls back to the older (uncached) feed RPC, at a gentler
// pace, until the get_cash_market_tick migration is deployed.
async function fetchTick() {
  if (tickSource === "live") {
    const { data, error } = await supabase.rpc("get_cash_market_tick");
    if (!error && data) {
      return {
        t: Date.now(),
        lifetime: Number(data.lifetime) || 0,
        money: Number(data.money) || 0,
        bank: Number(data.bank) || 0
      };
    }
    if (!isMissingFunction(error)) throw error;
    console.warn("[CASH MARKET] get_cash_market_tick missing; using the slower feed until it's deployed.");
    tickSource = "fallback";
  }

  const { data, error } = await supabase.rpc("get_global_cash_feed");
  if (error) throw error;
  const previous = latestRow();
  return {
    t: Date.now(),
    lifetime: Number(data?.total) || 0,
    money: Number(data?.cash) || 0,
    bank: previous?.bank ?? 0
  };
}

// Snapshots up to the first live tick, then the ticks themselves.
function allRows() {
  const firstTickAt = ticks[0]?.t ?? Infinity;
  return history.filter((row) => row.t < firstTickAt).concat(ticks);
}

function latestRow() {
  return ticks.at(-1) ?? history.at(-1) ?? null;
}

function windowedRows() {
  const merged = allRows();
  const { start } = historyWindow(merged, rangeHours(), Date.now());
  return merged.filter((row) => row.t >= start);
}

// Latest value at or before `at` — the "previous close" 24 hours ago.
function valueAt(list, at) {
  let found = list[0] ?? null;
  for (const row of list) {
    if (row.t > at) break;
    found = row;
  }
  return found ? found[metric] : null;
}

function lowHigh(list) {
  if (!list.length) return null;
  const values = list.map((row) => row[metric]);
  return [Math.min(...values), Math.max(...values)];
}

// ---------------------------------------------------------
// TICKER
// ---------------------------------------------------------

function paintTicker() {
  metricNameEl.textContent = METRIC_LABELS[metric];
  symbolEl.textContent = METRIC_SYMBOLS[metric];
  paintAsOf();

  if (rows.length === 0) {
    priceEl.textContent = "—";
    changeAbsEl.textContent = "—";
    changePctEl.textContent = "";
    changeRangeEl.textContent = "";
    changeEl.classList.remove("market__change--up", "market__change--down");
    return;
  }

  const first = rows[0][metric];
  const last = rows[rows.length - 1][metric];
  const diff = last - first;
  const pct = first > 0 ? (diff / first) * 100 : 0;
  const up = diff >= 0;

  priceEl.textContent = fullMoney(last);
  changeAbsEl.textContent = signedCompact(diff);
  changePctEl.textContent = "(" + signedPercent(pct) + ")";
  // Short ranges count as partial sooner than historyWindow's 10-minute grace.
  const { start } = historyWindow(rows, rangeHours(), Date.now());
  const grace = Math.min(600000, rangeHours() * 3600000 * 0.1);
  const partial = rows[0].t > start + grace;
  changeRangeEl.textContent = rangeId === "max" || partial
    ? "since first available sample"
    : RANGES[rangeId].label;
  if (rows.length === 1) {
    changeAbsEl.textContent = "—";
    changePctEl.textContent = "";
    changeRangeEl.textContent = "collecting ticks…";
  }
  changeEl.classList.toggle("market__change--up", up);
  changeEl.classList.toggle("market__change--down", !up);
}

function paintAsOf() {
  const latest = latestRow();
  if (document.hidden) {
    asOfEl.textContent = "Paused while this tab is hidden.";
  } else if (tickFailing) {
    asOfEl.textContent = "Reconnecting to the live quote…";
  } else if (latest) {
    const time = new Date(latest.t).toLocaleTimeString("en-US", {
      hour: "numeric", minute: "2-digit", second: "2-digit", timeZoneName: "short"
    });
    asOfEl.textContent = `As of ${time}. Market open.`;
  } else {
    asOfEl.textContent = "Connecting…";
  }
}

// Brief green/red flash on the price whenever a tick moves it.
function flashPrice(previousValue, nextValue) {
  if (previousValue == null || nextValue === previousValue) return;
  priceEl.classList.remove("market__price--flash-up", "market__price--flash-down");
  void priceEl.offsetWidth;
  priceEl.classList.add(nextValue > previousValue ? "market__price--flash-up" : "market__price--flash-down");
}

// Stats read compactly; the exact figure is on hover.
function setStat(name, text, exact = "") {
  statEls[name].textContent = text;
  statEls[name].title = exact;
}

function paintStats() {
  const merged = allRows();
  const now = Date.now();
  const dayRows = merged.filter((row) => row.t >= now - 24 * 3600000);
  const prevClose = valueAt(merged, now - 24 * 3600000);
  const dayRange = lowHigh(dayRows);
  const selectedRange = lowHigh(rows);

  const open = rows.length ? rows[0][metric] : null;
  setStat("prevClose", prevClose == null ? "—" : compact(prevClose), prevClose == null ? "" : fullMoney(prevClose));
  setStat("open", open == null ? "—" : compact(open), open == null ? "" : fullMoney(open));
  setStat(
    "dayRange",
    dayRange ? `${compact(dayRange[0])} – ${compact(dayRange[1])}` : "—",
    dayRange ? `${fullMoney(dayRange[0])} – ${fullMoney(dayRange[1])}` : ""
  );
  setStat(
    "range",
    selectedRange ? `${compact(selectedRange[0])} – ${compact(selectedRange[1])}` : "—",
    selectedRange ? `${fullMoney(selectedRange[0])} – ${fullMoney(selectedRange[1])}` : ""
  );

  const recent = ticks.filter((row) => row.t >= now - 60000);
  if (recent.length >= 2 && recent.at(-1).t > recent[0].t) {
    const minutes = (recent.at(-1).t - recent[0].t) / 60000;
    setStat("perMinute", signedCompact((recent.at(-1)[metric] - recent[0][metric]) / minutes));
  } else {
    setStat("perMinute", "—");
  }

  const lastTick = ticks.at(-1);
  setStat("lastTick", lastTick
    ? new Date(lastTick.t).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", second: "2-digit" })
    : "—");
}

// ---------------------------------------------------------
// CHART
// ---------------------------------------------------------

// Maps raw values onto the chosen y-axis scale. `base` is the range's
// opening value, used as the dashed baseline and the 0% line.
function buildScale(values, base, plotH) {
  if (scale === "log") {
    const [low, high] = logBounds(values.concat(base));
    const logLow = Math.log10(low);
    const logSpan = Math.log10(high) - logLow;
    const tickValues = logTicks(low, high, 4);
    return {
      toY: (value) => PAD.top + (1 - (Math.log10(Math.max(value, low)) - logLow) / logSpan) * plotH,
      ticks: tickValues.map((value, index) => ({
        value,
        label: axisMoney(value, Math.abs((tickValues[index + 1] ?? value * 2) - value))
      })),
      // Log steps scale with the value, so tags carry ~5 significant digits.
      format: (value) => axisMoney(value, Math.abs(value) * 1e-5)
    };
  }

  if (scale === "percent") {
    const toPercent = (value) => (base > 0 ? (value / base - 1) * 100 : 0);
    const [low, high] = fitBounds(values.map(toPercent).concat(0), 0, 0.005);
    const tickValues = niceTicks(low, high, 4);
    const step = tickValues.length > 1 ? tickValues[1] - tickValues[0] : high - low;
    return {
      toY: (value) => PAD.top + (1 - (toPercent(value) - low) / (high - low)) * plotH,
      ticks: tickValues.map((value) => ({ value: base * (1 + value / 100), label: axisPercent(value, step) })),
      format: (value) => signedPercent(toPercent(value), digitsForStep(step, 1) + 1)
    };
  }

  const [low, high] = fitBounds(values.concat(base));
  const tickValues = niceTicks(low, high, 4);
  const step = tickValues.length > 1 ? tickValues[1] - tickValues[0] : high - low;
  return {
    toY: (value) => PAD.top + (1 - (value - low) / (high - low)) * plotH,
    ticks: tickValues.map((value) => ({ value, label: axisMoney(value, step) })),
    format: (value) => axisMoney(value, step / 10)
  };
}

// A value tag pinned to the right-hand axis (current price, open, hover).
function axisTag(y, text, modifier) {
  const group = el("g", { class: `market__tag market__tag--${modifier}` });
  const rect = el("rect", { x: 0, y: y - 10, height: 20, rx: 4 });
  const label = el("text", { x: 0, y: y + 4 });
  label.textContent = text;
  group.appendChild(rect);
  group.appendChild(label);
  chart.appendChild(group);
  const x = layout ? layout.axisX : PAD.left;
  const width = Math.ceil(label.getComputedTextLength?.() || text.length * 7) + 12;
  rect.setAttribute("x", x);
  rect.setAttribute("width", width);
  label.setAttribute("x", x + 6);
  return group;
}

function draw() {
  chart.textContent = "";
  const w = wrap.clientWidth || 640;
  const h = wrap.clientHeight || 340;
  chart.setAttribute("viewBox", `0 0 ${w} ${h}`);
  chart.setAttribute("preserveAspectRatio", "none");

  if (rows.length === 0) {
    statusEl.hidden = false;
    statusEl.textContent = history.length || ticks.length
      ? "Waiting for the first ticks in this range…"
      : "No market data yet — check back soon.";
    layout = null;
    return;
  }
  statusEl.hidden = true;

  const plotW = w - PAD.left - PAD.right;
  const plotH = h - PAD.top - PAD.bottom;
  const axisX = PAD.left + plotW + 6;

  const values = rows.map((r) => r[metric]);
  const base = values[0];
  const yScale = buildScale(values, base, plotH);

  const { start: tMin, end: tMax } = historyWindow(rows, rangeHours(), Date.now());
  const tSpan = tMax - tMin || 1;

  const xOf = (t) => PAD.left + ((t - tMin) / tSpan) * plotW;
  const yOf = yScale.toY;

  // --- horizontal grid + y labels (right-hand axis) ---
  for (const tick of yScale.ticks) {
    const y = yOf(tick.value);
    if (y < PAD.top - 1 || y > PAD.top + plotH + 1) continue;
    chart.appendChild(el("line", {
      x1: PAD.left, y1: y, x2: PAD.left + plotW, y2: y,
      class: "market__grid"
    }));
    const label = el("text", { x: axisX + 6, y: y + 4, class: "market__ylabel" });
    label.textContent = tick.label;
    chart.appendChild(label);
  }

  // --- x labels ---
  const xTickCount = Math.max(2, Math.min(5, Math.floor(plotW / 110)));
  for (let i = 0; i < xTickCount; i++) {
    const t = tMin + (tSpan * i) / (xTickCount - 1);
    const x = xOf(t);
    const label = el("text", { x, y: h - 8, class: "market__xlabel" });
    label.textContent = timeLabel(t);
    if (i === 0) label.setAttribute("text-anchor", "start");
    else if (i === xTickCount - 1) label.setAttribute("text-anchor", "end");
    else label.setAttribute("text-anchor", "middle");
    chart.appendChild(label);
  }

  // --- points, thinned to one per pixel column ---
  const xs = rows.map((r) => xOf(r.t));
  const keptIndexes = decimateByPixel(xs);
  const pts = keptIndexes.map((index) => [xs[index], yOf(rows[index][metric])]);
  const pointRows = keptIndexes.map((index) => rows[index]);

  const last = values[values.length - 1];
  const up = last >= base;
  const trend = up ? "up" : "down";
  const baseY = yOf(base);

  layout = { w, h, plotW, plotH, axisX, pts, pointRows, trend, yScale, base };

  // dashed opening baseline
  chart.appendChild(el("line", {
    x1: PAD.left, y1: baseY, x2: PAD.left + plotW, y2: baseY,
    class: "market__baseline"
  }));

  if (pts.length > 1) {
    const linePath = pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ");
    const floorY = PAD.top + plotH;
    const areaPath = `M ${pts[0][0].toFixed(1)} ${floorY.toFixed(1)} `
      + pts.map((p) => "L" + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ")
      + ` L ${pts[pts.length - 1][0].toFixed(1)} ${floorY.toFixed(1)} Z`;

    const gradId = "market-fill";
    const defs = el("defs");
    const grad = el("linearGradient", { id: gradId, x1: "0", y1: "0", x2: "0", y2: "1" });
    grad.appendChild(el("stop", { offset: "0%", class: `market__fill-top market__fill-top--${trend}` }));
    grad.appendChild(el("stop", { offset: "100%", class: "market__fill-bottom" }));
    defs.appendChild(grad);
    chart.appendChild(defs);

    chart.appendChild(el("path", { d: areaPath, fill: `url(#${gradId})`, stroke: "none" }));
    chart.appendChild(el("path", { d: linePath, class: `market__line market__line--${trend}`, fill: "none" }));
  }

  // last-point marker with a soft halo
  const lastPt = pts[pts.length - 1];
  chart.appendChild(el("circle", { cx: lastPt[0], cy: lastPt[1], r: 7, class: `market__halo market__halo--${trend}` }));
  chart.appendChild(el("circle", { cx: lastPt[0], cy: lastPt[1], r: 3.5, class: `market__dot market__dot--${trend}` }));

  // axis tags: opening value, then the live price on top of it
  axisTag(baseY, scale === "percent" ? "0.00%" : yScale.format(base), "base");
  axisTag(lastPt[1], yScale.format(last), trend);

  // hover elements (hidden until pointer moves)
  const hoverLine = el("line", { class: "market__crosshair", y1: PAD.top, y2: PAD.top + plotH, x1: 0, x2: 0 });
  const hoverLineY = el("line", { class: "market__crosshair", x1: PAD.left, x2: PAD.left + plotW, y1: 0, y2: 0 });
  const hoverDot = el("circle", { r: 4.5, class: "market__hoverdot" });
  for (const node of [hoverLine, hoverLineY, hoverDot]) {
    node.style.opacity = "0";
    chart.appendChild(node);
  }
  Object.assign(layout, { hoverLine, hoverLineY, hoverDot, hoverTag: null });

  if (hoverX != null) showHover(hoverX);
}

// ---------------------------------------------------------
// HOVER
// ---------------------------------------------------------

function showHover(px) {
  if (!layout || layout.pts.length === 0) return;

  // nearest sample
  let best = 0, bestDist = Infinity;
  for (let i = 0; i < layout.pts.length; i++) {
    const d = Math.abs(layout.pts[i][0] - px);
    if (d < bestDist) { bestDist = d; best = i; }
  }
  const [x, y] = layout.pts[best];
  const row = layout.pointRows[best];
  const value = row[metric];
  const diff = value - layout.base;
  const pct = layout.base > 0 ? (diff / layout.base) * 100 : 0;

  layout.hoverLine.setAttribute("x1", x);
  layout.hoverLine.setAttribute("x2", x);
  layout.hoverLine.style.opacity = "1";
  layout.hoverLineY.setAttribute("y1", y);
  layout.hoverLineY.setAttribute("y2", y);
  layout.hoverLineY.style.opacity = "1";
  layout.hoverDot.setAttribute("cx", x);
  layout.hoverDot.setAttribute("cy", y);
  layout.hoverDot.style.opacity = "1";
  layout.hoverTag?.remove();
  layout.hoverTag = axisTag(y, layout.yScale.format(value), "hover");

  const tone = diff >= 0 ? "up" : "down";
  tooltip.hidden = false;
  tooltip.innerHTML = `<div class="market__tip-val">${fullMoney(value)}</div>`
    + `<div class="market__tip-change market__tip-change--${tone}">`
    + `${signedCompact(diff)} (${signedPercent(pct)})</div>`
    + `<div class="market__tip-time">${tooltipTime(row.t)}</div>`;

  // position tooltip within the wrap, following the point
  const rect = chart.getBoundingClientRect();
  const relX = (x / layout.w) * rect.width;
  const relY = (y / layout.h) * rect.height;
  const tipW = tooltip.offsetWidth;
  let left = relX - tipW / 2;
  left = Math.max(4, Math.min(left, rect.width - tipW - 4));
  tooltip.style.left = left + "px";
  tooltip.style.top = Math.max(4, relY - tooltip.offsetHeight - 14) + "px";
}

function onMove(event) {
  if (!layout || rows.length === 0) return;
  const rect = chart.getBoundingClientRect();
  hoverX = ((event.clientX - rect.left) / rect.width) * layout.w;
  showHover(hoverX);
}

function onLeave() {
  hoverX = null;
  tooltip.hidden = true;
  if (layout) {
    layout.hoverLine.style.opacity = "0";
    layout.hoverLineY.style.opacity = "0";
    layout.hoverDot.style.opacity = "0";
    layout.hoverTag?.remove();
    layout.hoverTag = null;
  }
}

// ---------------------------------------------------------
// LOAD + WIRING
// ---------------------------------------------------------

function render() {
  rows = windowedRows();
  paintTicker();
  draw();
  paintStats();
}

// Snapshot history. Always covers at least 24h so "previous close" and the
// day's range are available on the short ranges too.
async function refresh(showLoading = false) {
  const id = ++requestId;
  const requestedHours = Math.max(24, rangeHours());
  if (showLoading && !history.length && !ticks.length) {
    statusEl.hidden = false;
    statusEl.textContent = "Loading market data…";
  }
  try {
    const nextRows = await fetchHistory(requestedHours);
    if (id !== requestId) return;
    history = nextRows;
    render();
  } catch (error) {
    if (id !== requestId) return;
    console.error("[CASH MARKET] load failed:", error);
    if (!rows.length) {
      statusEl.hidden = false;
      statusEl.textContent = "Couldn't load market data. Retrying shortly…";
    }
  }
}

function addTick(sample) {
  const previous = latestRow();
  ticks.push(sample);
  const cutoff = sample.t - TICK_BUFFER_MS;
  while (ticks.length && ticks[0].t < cutoff) ticks.shift();
  flashPrice(previous?.[metric], sample[metric]);
  render();
}

async function pollTick() {
  if (tickInFlight) return;
  tickInFlight = true;
  clearTimeout(tickTimer);
  tickTimer = null;
  const startedAt = performance.now();
  try {
    addTick(await fetchTick());
    tickFailing = false;
  } catch (error) {
    if (!tickFailing) console.warn("[CASH MARKET] live tick failed:", error);
    tickFailing = true;
    paintAsOf();
  } finally {
    tickInFlight = false;
    scheduleTick(startedAt);
  }
}

// Next tick 0.7-1s after the previous one started (never overlapping).
function scheduleTick(startedAt = performance.now()) {
  if (document.hidden || tickTimer || tickInFlight) return;
  const interval = tickSource === "fallback" ? FALLBACK_TICK_MS : nextTickDelay();
  const wait = Math.max(0, interval - (performance.now() - startedAt));
  tickTimer = setTimeout(pollTick, wait);
}

function startPolling() {
  if (!historyTimer) historyTimer = setInterval(refresh, HISTORY_POLL_MS);
  scheduleTick(0);
}

function stopPolling() {
  clearInterval(historyTimer);
  historyTimer = null;
  clearTimeout(tickTimer);
  tickTimer = null;
  paintAsOf();
}

metricButtons.forEach((btn) => btn.addEventListener("click", () => {
  metric = btn.dataset.metric;
  syncControls();
  saveView();
  render();
}));

rangeButtons.forEach((btn) => btn.addEventListener("click", () => {
  rangeId = btn.dataset.range;
  onLeave();
  syncControls();
  saveView();
  render();
  refresh(true);
}));

scaleButtons.forEach((btn) => btn.addEventListener("click", () => {
  scale = btn.dataset.scale;
  syncControls();
  saveView();
  render();
}));

furnaceForm.addEventListener("submit", (event) => {
  event.preventDefault();
  requestBurn({ amount: furnaceInput.value });
});
document.querySelectorAll("[data-furnace-quick]").forEach((button) => {
  button.addEventListener("click", () => requestBurn({ amount: button.dataset.furnaceQuick }));
});
document.querySelector("[data-furnace-max]").addEventListener("click", () => requestBurn({ burnAll: true }));

chart.addEventListener("pointermove", onMove);
chart.addEventListener("pointerleave", onLeave);

let resizeRaf = null;
window.addEventListener("resize", () => {
  if (resizeRaf) cancelAnimationFrame(resizeRaf);
  resizeRaf = requestAnimationFrame(draw);
});

document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    stopPolling();
  } else {
    refresh();
    startPolling();
  }
});

loadView();
syncControls();
refresh(true);
refreshFurnace();
startPolling();
