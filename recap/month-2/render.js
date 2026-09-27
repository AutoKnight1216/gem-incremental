export const escapeHtml = (value) => String(value ?? "").replace(/[&<>"']/g,
  (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
export const number = (value, digits = 2) => Number(value ?? 0).toLocaleString("en-US", { maximumFractionDigits: digits });
const compact = (value) => Number(value ?? 0).toLocaleString("en-US", { notation: "compact", maximumFractionDigits: 2 });
const money = (value) => `$${compact(value)}`;
const percent = (value) => `${number(value)}%`;
const date = (value) => value ? new Date(value).toLocaleDateString("en-SG", {
  timeZone: "Asia/Singapore", day: "numeric", month: "short", year: "numeric"
}) : "—";
const scientific = (value) => {
  const n = Number(value ?? 0);
  return Number.isFinite(n) && Math.abs(n) >= 1e15 ? n.toExponential(3).replace("e+", "e") : number(n);
};
const stat = (label, value, note = "") => `<article class="recap-card"><h3>${escapeHtml(label)}</h3><strong>${escapeHtml(value)}</strong>${note ? `<small>${escapeHtml(note)}</small>` : ""}</article>`;
const section = (title, note, body) => `<section class="recap-section"><h2>${escapeHtml(title)}</h2><p class="section-note">${escapeHtml(note)}</p>${body}</section>`;

function comparison(label, before, after, formatter = number) {
  return `<article class="comparison-card"><h3>${escapeHtml(label)}</h3><div class="comparison-values">
    <div><span>MONTH ONE</span><strong class="month-one-value">${escapeHtml(formatter(before))}</strong></div>
    <b class="comparison-arrow">→</b>
    <div><span>MONTH TWO</span><strong class="month-two-value">${escapeHtml(formatter(after))}</strong></div>
  </div></article>`;
}

function movement(before, after) {
  if (before == null) return `<span class="movement__new">#${number(after, 0)}</span>`;
  const delta = Number(before) - Number(after);
  const label = delta > 0 ? `▲${delta}` : delta < 0 ? `▼${Math.abs(delta)}` : "NO CHANGE";
  const klass = delta > 0 ? "" : delta < 0 ? " is-down" : " is-flat";
  return `<span class="movement__old">#${number(before, 0)}</span><span>→</span><span class="movement__new">#${number(after, 0)}</span><span class="movement__delta${klass}">${label}</span>`;
}

function metricValue(record, metric) {
  if (metric === "value") return money(record.value);
  if (metric === "weight") return `${number(record.weight)} g`;
  if (metric === "mutations") return `${number(record.score, 0)} mutation${Number(record.score) === 1 ? "" : "s"}`;
  if (metric === "combo") return `${scientific(record.score)}× combo`;
  return `1 / ${number(metric === "raw" ? record.rawRarity : record.rarity)}`;
}

export function recordCard(title, record, metric = "rarity", previous = null) {
  if (!record?.gem || Number(record.rarity) <= 0) return `<article class="recap-card"><h3>${escapeHtml(title)}</h3><p>No qualifying recorded roll.</p></article>`;
  const beatPrevious = previous?.score != null && Number(record.score) > Number(previous.score);
  const verdict = previous?.score == null ? "" : beatPrevious
    ? '<span class="record-verdict record-verdict--new">NEW RECORD</span>'
    : '<span class="record-verdict record-verdict--held">MONTH ONE STILL UNBEATEN</span>';
  return `<article class="recap-card recap-card--accent"><h3>${escapeHtml(title)}</h3>
    <strong class="gem-name">${escapeHtml(record.gem)}</strong><p>${escapeHtml(metricValue(record, metric))}</p>
    ${record.username ? `<p>${escapeHtml(record.username)}</p>` : ""}
    ${metric !== "rarity" ? `<small>Displayed rarity: 1 / ${number(record.rarity)}</small>` : ""}
    <p>🍀 ${record.luck == null ? "Roll-time luck not recorded" : `${number(record.luck)}× luck at this roll`}</p>
    ${record.mutations?.length ? `<small>${record.mutations.map(escapeHtml).join(" + ")}</small>` : ""}
    ${record.at ? `<p><small>${escapeHtml(date(record.at))}</small></p>` : ""}${verdict}
    ${previous?.score != null ? `<p><small>Month One: ${escapeHtml(metricValue(previous, metric))}</small></p>` : ""}
  </article>`;
}

function minigames(games = []) {
  if (!games.length) return "<p>No recorded Month Two minigame runs.</p>";
  return `<div class="recap-table-wrap"><table><caption>Sep 8–Oct 8 completed scores</caption><thead><tr><th>Game</th><th>Runs</th><th>Best result</th></tr></thead><tbody>
    ${games.map((game) => `<tr><th>${escapeHtml(String(game.game).replaceAll("-", " ").replace(/\b\w/g, (c) => c.toUpperCase()))}</th>
      <td>${number(game.runs, 0)}${game.rank ? `<br><small>#${number(game.rank, 0)} / ${number(game.participants, 0)}</small>` : ""}</td>
      <td>${game.best_score == null ? "—" : number(game.best_score)}${game.best_player ? `<br><small>${escapeHtml(game.best_player)}</small>` : ""}</td></tr>`).join("")}
    </tbody></table></div>`;
}

export function globalRecap(data) {
  const global = data.global;
  const totals = global.totals;
  const monthOne = global.monthOne;
  const old = monthOne.totals;
  const records = global.records;
  const oldRecords = monthOne.records ?? {};
  const top = global.topRollers?.[0];
  return `<div class="stat-grid">${stat("Month Two rolls", compact(totals.rolls), `${number(totals.rolls, 0)} rolls`)}
    ${stat("Players joined", number(totals.new_players, 0))}${stat("Month Two earnings", money(totals.earned))}
    ${stat("Money burned", money(totals.burned))}</div>`
    + section("One Month Later", "The same definitions, one month apart.", `<div class="comparison-grid">
      ${comparison("Rolls", old.rolls, totals.rolls, compact)}${comparison("Eligible players", old.players, totals.players)}
      ${comparison("Earnings", old.earned, totals.earned, money)}${comparison("Money burned", old.burned, totals.burned, money)}
      ${comparison("Median rolls", old.median_rolls, totals.median_rolls)}${comparison("1K+ rollers", old.rollers_1k, totals.rollers_1k)}
      ${comparison("10K+ rollers", old.rollers_10k, totals.rollers_10k)}${comparison("100K+ rollers", old.rollers_100k, totals.rollers_100k)}
      ${comparison("Minigame runs", monthOne.minigameRuns, global.minigameRuns)}${comparison("Minigame players", monthOne.minigamePlayers, global.minigamePlayers)}
    </div>`)
    + section("Against All Odds", "Displayed rarity and luck-adjusted raw rarity remain separate records.",
      `<div class="record-grid">${recordCard("Highest Displayed Rarity", records.displayed, "rarity", oldRecords.displayed)}
      ${recordCard("Best Raw Rare Roll", records.raw, "raw", oldRecords.raw)}</div>`)
    + section("Hall of Fame", "Six records, with their Month One challengers beside them.", `<div class="record-grid">
      ${recordCard("Highest Displayed", records.displayed, "rarity", oldRecords.displayed)}
      ${recordCard("Best Raw Rare Roll", records.raw, "raw", oldRecords.raw)}
      ${recordCard("Most Valuable", records.value, "value", oldRecords.value)}
      ${recordCard("Heaviest Recorded Roll", records.weight, "weight", oldRecords.weight)}
      ${recordCard("Most Mutations", records.mutations, "mutations", oldRecords.mutations)}
      ${recordCard("Best Mutation Combo", records.combo, "combo", oldRecords.combo)}</div>
      <p class="section-note">Weight history for Month Two begins 11 September. Other historical candidates are best-effort until reusable per-roll capture begins; no exact mutated-roll total is claimed.</p>`)
    + section("The Grind", "Period totals come from frozen lifetime-counter deltas, using players.total_rolls.",
      `<p class="recap-callout">${top ? `${escapeHtml(top.username)} led Month Two with <b>${number(top.rolls, 0)}</b> rolls. ` : ""}The top ten produced <b>${percent(global.topTenShare)}</b> of Month Two rolls.</p>
      <div class="stat-grid">${stat("Median Month Two rolls", number(totals.median_rolls))}${stat("Active rollers", number(totals.active_players, 0))}
      ${stat("1K+ rollers", number(totals.rollers_1k, 0))}${stat("10K+ rollers", number(totals.rollers_10k, 0))}${stat("100K+ rollers", number(totals.rollers_100k, 0))}</div>`)
    + section("The Economy™", "Another month of numbers behaving questionably.",
      `<div class="stat-grid">${stat("Month Two earnings", money(totals.earned))}${stat("Month Two burned", money(totals.burned))}
      ${stat("Net generated", money(Number(totals.earned) - Number(totals.burned)))}
      ${records.value ? stat("Largest recorded roll value", money(records.value.value), records.value.username) : ""}
      ${global.richest ? stat("Richest eligible player", money(global.richest.money), global.richest.username) : ""}</div>`)
    + section("Month Two Minigames", "Each game keeps its existing score and tie-field ordering.",
      `<div class="stat-grid">${stat("Recorded runs", number(global.minigameRuns, 0))}${stat("Players", number(global.minigamePlayers, 0))}${stat("Games", number(global.minigames.length, 0))}</div>${minigames(global.minigames)}`);
}

export function shareSummary(data) {
  const personal = data.personal;
  if (!personal) return "";
  const rare = personal.highestDisplayed;
  const raw = personal.rawRare;
  const rank = personal.monthOne?.rollRank != null ? `#${personal.monthOne.rollRank} → #${personal.rollRank}` : `#${personal.rollRank}`;
  return `💎 GEM RNG — MONTH TWO${data.status === "finalizing" ? " (FINALIZING)" : ""}\n${personal.username}\n`
    + `${number(personal.monthTwoRolls, 0)} rolls · Top ${personal.rollTopPercent}%\n`
    + `Rarest: ${rare?.gem ?? "Still rolling"}${rare?.rarity ? ` · 1 / ${number(rare.rarity, 0)}` : ""}\n`
    + `Raw Rare Roll: ${raw?.rawRarity ? `1 / ${number(raw.rawRarity)}` : "—"}\n`
    + `${money(personal.monthTwoEarned)} earned\nRoll rank: ${rank}\nOCTOBER 2026`;
}

export function personalRecap(data) {
  const p = data.personal;
  if (!p) return section("Your Month Two", "Your own part of the second month.",
    '<p>Sign in with an eligible account to see your personal Month Two recap.</p><a href="../../account/">Open your account →</a>');
  const previous = p.monthOne;
  const personalRecords = p.records ?? {};
  return `<div class="recap-transition"><p>YOUR MONTH TWO</p><h2>You rolled ${number(p.monthTwoRolls, 0)} times.</h2>
    <p>${p.newPlayer ? "You joined us this month." : `${number(Number(p.monthTwoRolls) - Number(previous?.rolls ?? 0), 0)} compared with Month One.`}</p></div>`
    + section("Your Grind", "Your place in the Month Two community.", `<div class="stat-grid">
      ${stat("Month Two rolls", number(p.monthTwoRolls, 0))}${stat("Lifetime rolls", number(p.lifetimeRolls, 0))}
      <article class="recap-card"><h3>Roll rank</h3><strong class="movement">${movement(previous?.rollRank, p.rollRank)}</strong><small>Top ${p.rollTopPercent}% of ${number(p.population, 0)}</small></article>
      ${stat("Community share", percent(p.rollShare))}</div>`)
    + section("Your Economy", "Period deltas from the frozen Sep 8 baseline.", `<div class="stat-grid">
      ${stat("Month Two earnings", money(p.monthTwoEarned))}${stat("Lifetime earnings", money(p.lifetimeEarned))}
      ${stat("Month Two burned", money(p.monthTwoBurned))}
      <article class="recap-card"><h3>Earnings rank</h3><strong class="movement">${movement(previous?.earningsRank, p.earningsRank)}</strong><small>Top ${p.earningsTopPercent}%</small></article></div>`)
    + section("Your Greatest Discoveries", "Displayed rarity and raw luck-adjusted rarity are intentionally separate.",
      `<div class="record-grid">${recordCard("Highest Displayed Rarity", p.highestDisplayed, "rarity", previous?.records?.displayed)}
      ${recordCard("Best Raw Rare Roll", p.rawRare, "raw", previous?.records?.raw)}</div>`)
    + section("Your Records", "Personal candidates captured for value, weight, mutations, and combo.", `<div class="record-grid">
      ${recordCard("Most Valuable", personalRecords.value, "value", previous?.records?.value)}
      ${recordCard("Heaviest Recorded Roll", personalRecords.weight, "weight", previous?.records?.weight)}
      ${recordCard("Most Mutations", personalRecords.mutations, "mutations", previous?.records?.mutations)}
      ${recordCard("Best Mutation Combo", personalRecords.combo, "combo", previous?.records?.combo)}</div>`)
    + section("Your Minigames", "Only games you played during Month Two appear here.", minigames(p.minigames))
    + section("You Were Here", p.newPlayer ? "You joined during Month Two." : "One of the Month One originals.",
      `<p class="recap-callout">Eligible player <b>#${number(p.joinNumber, 0)}</b>.<br>Joined ${escapeHtml(date(p.joined))}.</p>`)
    + section("Your Month Two Card", "A compact piece of Gem RNG history.",
      `<div class="share-card share-card--two"><pre>${escapeHtml(shareSummary(data))}</pre></div>
      <div class="share-actions"><button type="button" id="share-summary">Share Month Two</button><button type="button" id="copy-summary">Copy summary</button><button type="button" id="download-summary">Save card as SVG</button></div><p id="share-status" role="status" aria-live="polite"></p>`);
}

export function summarySvg(data) {
  const lines = shareSummary(data).split("\n");
  return `<svg xmlns="http://www.w3.org/2000/svg" width="800" height="520" viewBox="0 0 800 520">
    <defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#17152c"/><stop offset="1" stop-color="#101b29"/></linearGradient></defs>
    <rect width="800" height="520" rx="28" fill="url(#bg)"/><path d="M120 35 250 105 220 460 70 350Z" fill="none" stroke="#806fd0" opacity=".45"/><path d="m680 35-130 70 30 355 150-110Z" fill="none" stroke="#76bce8" opacity=".45"/>
    ${lines.map((line, index) => `<text x="48" y="${75 + index * 48}" font-family="Arial,sans-serif" font-size="${index === 0 ? 25 : 21}" fill="${index === 0 ? "#b8dfff" : "#f2efff"}"${line.length > 52 ? ' textLength="704" lengthAdjust="spacingAndGlyphs"' : ""}>${escapeHtml(line)}</text>`).join("")}</svg>`;
}
