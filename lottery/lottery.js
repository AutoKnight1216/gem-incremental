import { mountShell } from "../src/ui/shell.js";
import { formatMoney, escapeHtml } from "../src/ui/format.js";
import { confirmDialog } from "../src/ui/dialog.js";
import { notify } from "../src/ui/toast.js";
import { loadDailyLottery, purchaseLotteryTickets, acknowledgeLotteryWin } from "../src/backend/cloudLottery.js";

mountShell({ page: "lottery", base: "../" });

const TICKET_PRICE = 10_000;
const MAX_QUANTITY = 900_000_000_000;
const $ = (id) => document.getElementById(id);
const exactTickets = (value) => {
  try { return BigInt(String(value ?? 0)).toLocaleString("en-US"); }
  catch { return Math.max(0,Math.floor(Number(value)||0)).toLocaleString("en-US"); }
};
const ticketsAfter = (current, added) => {
  try { return exactTickets(BigInt(String(current ?? 0)) + BigInt(added)); }
  catch { return exactTickets(Number(current || 0) + added); }
};
let data = null;
let busy = false;
let serverOffset = 0;
let boundaryRefresh = null;

function quantity() {
  const value = Number($("ticketQuantity").value);
  return Number.isSafeInteger(value) && value >= 1 && value <= MAX_QUANTITY ? value : 0;
}

function selectedFunding() {
  return document.querySelector('input[name="funding"]:checked')?.value || "wallet";
}

function cost() {
  return quantity() * TICKET_PRICE;
}

function countdown(target) {
  const seconds = Math.max(0, Math.ceil((new Date(target).getTime() - (Date.now() + serverOffset)) / 1000));
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = seconds % 60;
  return hours ? `${hours}h ${String(minutes).padStart(2,"0")}m ${String(secs).padStart(2,"0")}s` : `${minutes}m ${String(secs).padStart(2,"0")}s`;
}

function updatePurchasePreview() {
  const amount = quantity();
  const total = cost();
  $("purchaseCost").textContent = amount ? formatMoney(total, { exact: true }) : "Enter a whole number";
  $("afterPurchase").textContent = amount && data
    ? `Your tickets after purchase: ${ticketsAfter(data.ownTickets,amount)}`
    : "Your tickets after purchase: —";
  $("buyTickets").disabled = busy || data?.phase !== "open" || !amount;
}

function renderStatus() {
  if (!data) return;
  const status = $("lotteryStatus");
  let title;
  let detail;
  let target;
  if (data.phase === "open") {
    title = data.activityBand;
    detail = "Entries close in";
    target = data.cutoffAt;
  } else if (data.phase === "locked") {
    title = "Entries for today's lottery are closed.";
    detail = "Winner drawn in";
    target = data.drawAt;
  } else {
    title = "The next lottery is being prepared.";
    detail = "Ticket sales open in";
    target = data.nextSalesOpenAt;
  }
  status.innerHTML = `<div><p class="lottery-kicker">${escapeHtml(data.phase)}</p><h2>${escapeHtml(title)}</h2><p>${escapeHtml(detail)} <strong data-countdown>${escapeHtml(countdown(target))}</strong></p></div><div class="lottery-ticket-price"><span>Ticket price</span><strong>${formatMoney(data.ticketPrice, { exact: true })}</strong></div>`;
  clearTimeout(boundaryRefresh);
  const delay = Math.max(1000, new Date(target).getTime() - (Date.now() + serverOffset) + 750);
  boundaryRefresh = setTimeout(refresh, Math.min(delay, 2_147_000_000));
}

function renderResults() {
  const rows = data?.recentResults || [];
  $("recentResults").innerHTML = rows.length
    ? `<ol class="lottery-history">${rows.map((row) => `<li><time datetime="${escapeHtml(row.date)}">${new Date(`${row.date}T12:00:00`).toLocaleDateString(undefined,{day:"numeric",month:"short"})}</time><span>${row.hadWinner ? `<strong>${escapeHtml(row.winnerUsername)}</strong> won <strong>${formatMoney(row.prize, { exact: true })}</strong>` : "No tickets were purchased."}</span></li>`).join("")}</ol>`
    : `<p class="lottery-empty">No completed draws yet.</p>`;
}

function render() {
  renderStatus();
  $("ownTickets").textContent = `Your tickets: ${exactTickets(data.ownTickets)}`;
  $("walletBalance").textContent = formatMoney(data.walletBalance, { exact: true });
  $("bankBalance").textContent = formatMoney(data.bankBalance, { exact: true });
  renderResults();
  updatePurchasePreview();
}

async function showUnreadWin(win) {
  await confirmDialog({
    title: "You won the Daily Lottery!",
    body: `<p>Your prize from the ${escapeHtml(new Date(`${win.date}T12:00:00`).toLocaleDateString())} draw was <strong>${formatMoney(win.prize, { exact: true })}</strong>.</p><p>The prize has already been credited to your wallet.</p>`,
    confirmLabel: "Got it",
    cancelLabel: "Close",
    defaultAction: "confirm"
  });
  await acknowledgeLotteryWin(win.drawId);
}

async function refresh({ quiet = false } = {}) {
  const result = await loadDailyLottery();
  if (result.error) {
    if (!quiet) $("lotteryStatus").innerHTML = `<p>${escapeHtml(result.error.message)}</p>`;
    return;
  }
  data = result.data;
  serverOffset = new Date(data.serverNow).getTime() - Date.now();
  render();
  if (data.unreadWin) {
    const win = data.unreadWin;
    data.unreadWin = null;
    await showUnreadWin(win);
    await refresh({ quiet: true });
  }
}

async function confirmLargePurchase(amount, tickets) {
  if (amount < 10_000_000) return true;
  const veryLarge = amount >= 100_000_000;
  const answer = await confirmDialog({
    title: veryLarge ? "Large Lottery Purchase" : "Confirm Lottery Purchase",
    body: `<p>You're about to spend <strong>${formatMoney(amount, { exact: true })}</strong> on <strong>${exactTickets(tickets)} tickets</strong> from your ${escapeHtml(selectedFunding())}.</p>${veryLarge ? "<p><strong>Winning is not guaranteed regardless of how many tickets you purchase.</strong></p>" : "<p>Tickets cannot be refunded or transferred.</p>"}`,
    confirmLabel: `Spend ${formatMoney(amount, { exact: true })}`,
    defaultAction: "cancel",
    preventEnter: true,
    tone: veryLarge ? "danger" : "default"
  });
  return answer === "confirm";
}

async function buy() {
  if (busy || !data || data.phase !== "open") return;
  const tickets = quantity();
  const amount = cost();
  if (!tickets) {
    notify.error("Daily Lottery", "Enter a valid whole number of tickets.");
    return;
  }
  if (!await confirmLargePurchase(amount, tickets)) return;
  busy = true;
  updatePurchasePreview();
  try {
    const result = await purchaseLotteryTickets(tickets, selectedFunding());
    if (result.error) {
      notify.error("Daily Lottery", result.error.message);
    } else if (!result.data?.ok) {
      notify.error("Daily Lottery", result.data?.message || "The purchase was rejected. You were not charged.");
    } else {
      notify.success("Tickets purchased", `${exactTickets(result.data.ticketsPurchased)} tickets for ${formatMoney(result.data.cost, { exact: true })}.`);
      data.ownTickets = result.data.ownTickets;
      data.activityBand = result.data.activityBand;
      data.walletBalance = result.data.walletBalance;
      data.bankBalance = result.data.bankBalance;
      render();
    }
  } finally {
    busy = false;
    updatePurchasePreview();
  }
}

document.addEventListener("click", (event) => {
  const quick = event.target.closest("[data-quantity]");
  if (quick) {
    $("ticketQuantity").value = quick.dataset.quantity;
    updatePurchasePreview();
  }
  if (event.target.closest("[data-custom]")) {
    $("ticketQuantity").focus();
    $("ticketQuantity").select();
  }
});
$("ticketQuantity").addEventListener("input", updatePurchasePreview);
$("buyTickets").addEventListener("click", buy);
setInterval(() => {
  const node = document.querySelector("[data-countdown]");
  if (!node || !data) return;
  const target = data.phase === "open" ? data.cutoffAt : data.phase === "locked" ? data.drawAt : data.nextSalesOpenAt;
  node.textContent = countdown(target);
}, 1000);
setInterval(() => refresh({ quiet: true }), 15_000);
refresh();
