import { mountShell } from "../src/ui/shell.js";
import { loadBankDashboard, bankDeposit, bankWithdraw, bankBorrow, bankRepay, bankDeclareBankruptcy,
  loadBankCheques, bankIssueCheque, bankCashCheque, bankCancelCheque } from "../src/backend/cloudBank.js";
import { formatMoney, escapeHtml, formatRelativeTime } from "../src/ui/format.js";
import { confirmDialog } from "../src/ui/dialog.js";
import { notify } from "../src/ui/toast.js";

mountShell({ page: "bank", base: "../" });

const $ = (id) => document.getElementById(id);
const money = (value) => formatMoney(Number(value || 0));
const chequeMoney = (value) => formatMoney(Number(value || 0), { decimalPlaces: 2 });
const percent = (rate) => `${(Number(rate || 0) * 100).toFixed(2)}%`;
// The daily savings rate is tiny (0.012%), so it needs finer precision than APR.
const rateFine = (rate) => `${(Number(rate || 0) * 100).toFixed(3)}%`;
const round = (value) => Math.max(0, Math.floor(Number(value) || 0));

let data = null;
let cheques = null;
let chequeError = null;
let incomingOffset = 0;
let outgoingOffset = 0;
let busy = false;

const KIND_LABEL = {
  deposit: "Deposit", withdraw: "Withdrawal", borrow: "Loan drawn", repay: "Repayment",
  interest: "Savings interest", loan_interest: "Loan interest", penalty: "Late penalty",
  seizure: "Savings seized", bankruptcy: "Bankruptcy", lottery: "Daily Lottery tickets",
  cheque_issue: "Cheque written", cheque_receive: "Cheque cashed", cheque_refund: "Cheque cancelled"
};
// Money leaving the wallet/savings reads as negative for the player.
const KIND_SIGN = {
  deposit: -1, withdraw: 1, borrow: 1, repay: -1,
  interest: 1, loan_interest: 0, penalty: 0, seizure: -1, bankruptcy: 0, lottery: -1,
  cheque_issue: -1, cheque_receive: 1, cheque_refund: 1
};

function render() {
  if (!data) return;
  const owed = Number(data.loan_total || 0);
  $("status").innerHTML = `
    <div><span>Wallet</span><strong>${money(data.money)}</strong></div>
    <div><span>In savings</span><strong>${money(data.balance)}</strong></div>
    <div><span>Owed</span><strong class="${owed > 0 ? "bank-owed" : ""}">${money(owed)}</strong></div>
    <div><span>Credit</span><strong>${data.credit_score} · ${escapeHtml(data.credit_band)}</strong></div>`;

  $("savings").innerHTML = `
    <p class="bank-figure">${money(data.balance)}<small>current balance</small></p>
    <p class="bank-note">Earns <strong>${rateFine(data.savings_daily_rate)}</strong> per day, compounding — about <strong>${percent(data.savings_apy)}</strong> APY. Interest is credited whenever you visit.</p>
    <div class="bank-field">
      <label for="savingsAmount">Amount</label>
      <input id="savingsAmount" type="number" min="1" step="1" inputmode="numeric" placeholder="0">
    </div>
    <div class="bank-actions">
      <button class="btn btn--primary" data-action="deposit" data-input="savingsAmount" ${busy ? "disabled" : ""}>Deposit</button>
      <button class="btn" data-action="withdraw" data-input="savingsAmount" ${busy ? "disabled" : ""}>Withdraw</button>
    </div>`;

  const creditPercent = Math.max(0, Math.min(100, (data.credit_score - 300) / 550 * 100));
  $("credit").innerHTML = `
    <p class="bank-figure">${data.credit_score}<small>${escapeHtml(data.credit_band)} · 300–850</small></p>
    <div class="credit-meter"><i style="width:${creditPercent}%"></i></div>
    <p class="bank-note">On-time repayments raise your score and unlock a larger, cheaper line of credit. Missing a due date charges a late fee and drops it.</p>
    <ul class="bank-stats">
      <li><span>On-time payoffs</span><strong>${data.on_time_repayments}</strong></li>
      <li><span>Missed payments</span><strong>${data.missed_marks}</strong></li>
      ${data.bankruptcies > 0 ? `<li><span>Bankruptcies</span><strong>${data.bankruptcies}</strong></li>` : ""}
      <li><span>Your loan APR</span><strong>${percent(data.loan_apr)}</strong></li>
    </ul>`;

  renderCheques();

  const due = data.loan_due_at
    ? `<strong>${new Date(data.loan_due_at).toLocaleDateString()}</strong> (${escapeHtml(formatRelativeTime(data.loan_due_at))})`
    : "—";
  const canBorrow = !data.in_default && !data.borrow_frozen;
  let banner = "";
  if (data.in_default) {
    banner = `<p class="bank-banner bank-banner--danger"><strong>Loan in default.</strong> Your savings are being seized to cover it, and late fees keep accruing. Repay what you can — or, if you truly can't, declare bankruptcy to discharge the rest.</p>`;
  } else if (data.borrow_frozen) {
    banner = `<p class="bank-banner"><strong>Borrowing frozen</strong> after bankruptcy until ${new Date(data.borrow_frozen_until).toLocaleDateString()} (${escapeHtml(formatRelativeTime(data.borrow_frozen_until))}). Keep saving to rebuild your credit.</p>`;
  }
  $("loan").innerHTML = `
    ${banner}
    <div class="bank-loan-grid">
      <div><span>Outstanding principal</span><strong>${money(data.loan_principal)}</strong></div>
      <div><span>Accrued interest</span><strong>${money(data.loan_interest)}</strong></div>
      <div><span>Total owed</span><strong class="${owed > 0 ? "bank-owed" : ""}">${money(owed)}</strong></div>
      <div><span>Payment due</span><strong>${due}</strong></div>
      <div><span>Borrow limit</span><strong>${money(data.borrow_limit)}</strong></div>
      <div><span>Available credit</span><strong>${money(data.available_credit)}</strong></div>
    </div>
    <p class="bank-note">Loans draw on a 7-day term at <strong>${percent(data.loan_apr)}</strong> APR. Interest is paid before principal; savings count as collateral toward your limit and are seized first if you default.</p>
    <div class="bank-field">
      <label for="loanAmount">Amount</label>
      <input id="loanAmount" type="number" min="1" step="1" inputmode="numeric" placeholder="0">
    </div>
    <div class="bank-actions">
      <button class="btn btn--primary" data-action="borrow" data-input="loanAmount" ${busy || !canBorrow ? "disabled" : ""}>Borrow</button>
      <button class="btn" data-action="repay" data-input="loanAmount" ${busy || owed <= 0 ? "disabled" : ""}>Repay</button>
      ${data.in_default ? `<button class="btn btn--danger" data-action="bankruptcy" ${busy ? "disabled" : ""}>Declare bankruptcy</button>` : ""}
    </div>`;

  const rows = data.transactions || [];
  $("ledger").innerHTML = rows.length
    ? `<ul class="bank-ledger">${rows.map(ledgerRow).join("")}</ul>`
    : `<p class="bank-note">No activity yet. Make your first deposit to start earning interest.</p>`;
}

function chequeRow(row, direction) {
  const incoming = direction === "incoming";
  const name = incoming ? row.sender_name : row.recipient_name;
  const action = row.status === "pending"
    ? `<button class="btn ${incoming ? "btn--primary" : ""}" type="button"
        data-action="cheque-${incoming ? "cash" : "cancel"}" data-cheque-id="${escapeHtml(row.id)}" ${busy ? "disabled" : ""}>
        ${incoming ? "Cash cheque" : "Cancel cheque"}</button>`
    : "";
  return `<li class="bank-cheque-row">
    <div><strong>${incoming ? "From" : "To"} ${escapeHtml(name || "Player")}</strong>
      <small>Cheque #${escapeHtml(row.id)} · ${escapeHtml(row.status)} · ${escapeHtml(formatRelativeTime(row.created_at))}</small>
      <small>Face ${chequeMoney(row.face_amount)} · tax ${chequeMoney(row.tax_amount)} · recipient gets ${chequeMoney(row.net_amount)}</small></div>
    ${action}</li>`;
}

function renderCheques() {
  if (!cheques) {
    $("cheques").innerHTML = `<p class="bank-note">${escapeHtml(chequeError || "Loading cheques…")}</p>`;
    return;
  }
  const incomingPage = cheques.incoming || [];
  const outgoingPage = cheques.outgoing || [];
  const incoming = incomingPage.slice(0, 30);
  const outgoing = outgoingPage.slice(0, 30);
  $("cheques").innerHTML = `
    <p class="bank-note">Write a cheque to another player's username. The face value leaves your wallet now.
      When they cash it, <strong>7.5% is removed as tax</strong> and they receive the rest.
      You can cancel an uncashed cheque for a full refund. Up to 20 cheques may be pending at once.</p>
    <div class="bank-cheque-form">
      <div class="bank-field"><label for="chequeRecipient">Recipient username</label>
        <input id="chequeRecipient" type="text" maxlength="20" autocomplete="off" placeholder="Player name"></div>
      <div class="bank-field"><label for="chequeAmount">Face value</label>
        <input id="chequeAmount" type="number" min="1" max="1000000000000" step="1" inputmode="numeric" placeholder="0"></div>
    </div>
    <p class="bank-note" id="chequeQuote" aria-live="polite">Enter an amount to see the tax and payout.</p>
    <div class="bank-actions"><button class="btn btn--primary" type="button" data-action="cheque-issue"
      data-input="chequeAmount" ${busy ? "disabled" : ""}>Write cheque</button></div>
    <div class="bank-cheque-lists">
      <section><h3>To cash</h3>${incoming.length
        ? `<ul class="bank-cheque-list">${incoming.map((row) => chequeRow(row, "incoming")).join("")}</ul>`
        : '<p class="bank-note">No cheques on this page.</p>'}
        ${chequePages("incoming", incomingOffset, incomingPage.length > 30)}</section>
      <section><h3>Written</h3>${outgoing.length
        ? `<ul class="bank-cheque-list">${outgoing.map((row) => chequeRow(row, "outgoing")).join("")}</ul>`
        : '<p class="bank-note">No cheques on this page.</p>'}
        ${chequePages("outgoing", outgoingOffset, outgoingPage.length > 30)}</section>
    </div>`;
}

function chequePages(direction, offset, hasMore) {
  if (!offset && !hasMore) return "";
  return `<div class="bank-cheque-pages">
    <button class="btn" type="button" data-cheque-page="${direction}-prev" ${!offset || busy ? "disabled" : ""}>Previous</button>
    <span>Page ${Math.floor(offset / 30) + 1}</span>
    <button class="btn" type="button" data-cheque-page="${direction}-next" ${!hasMore || busy ? "disabled" : ""}>Next</button>
  </div>`;
}

function updateChequeQuote() {
  const amount = Number($("chequeAmount")?.value || 0);
  const quote = $("chequeQuote");
  if (!quote) return;
  if (!Number.isSafeInteger(amount) || amount < 1 || amount > 1e12) {
    quote.textContent = "Enter a whole-dollar amount from $1 to $1 trillion.";
    return;
  }
  const tax = Math.round(amount * 7.5) / 100;
  quote.textContent = `${chequeMoney(amount)} from your wallet · ${chequeMoney(tax)} tax · ${chequeMoney(amount - tax)} to the recipient.`;
}

function ledgerRow(row) {
  const sign = KIND_SIGN[row.kind] ?? 0;
  const cls = sign > 0 ? "is-in" : sign < 0 ? "is-out" : "is-neutral";
  const prefix = sign > 0 ? "+" : sign < 0 ? "−" : "";
  return `<li class="${cls}">
    <div><strong>${escapeHtml(KIND_LABEL[row.kind] || row.kind)}</strong><small>${escapeHtml(row.memo || "")}</small></div>
    <div class="bank-ledger__amount">${prefix}${money(row.amount)}<small>${escapeHtml(formatRelativeTime(row.created_at))}</small></div>
  </li>`;
}

function readAmount(inputId) {
  const input = $(inputId);
  return round(input?.value);
}

async function act(action, amount, recipient, chequeId) {
  if (action === "bankruptcy") {
    const ok = await confirmDialog({
      title: "Declare bankruptcy?",
      body: `<p>This discharges your remaining ${money(data.loan_total)} of debt.</p>
             <p><strong>Your credit score resets to 300</strong> and borrowing is frozen for 14 days. Your savings have already gone toward the loan. This cannot be undone.</p>`,
      confirmLabel: "Declare bankruptcy",
      defaultAction: "cancel",
      preventEnter: true
    });
    if (ok !== "confirm") return;
    return bankDeclareBankruptcy();
  }

  if (action === "cheque-cash") return bankCashCheque(chequeId);
  if (action === "cheque-cancel") {
    const ok = await confirmDialog({
      title: "Cancel this cheque?",
      body: "<p>The full face value will return to your wallet. The recipient will no longer be able to cash it.</p>",
      confirmLabel: "Cancel cheque", defaultAction: "cancel", preventEnter: true
    });
    if (ok !== "confirm") return;
    return bankCancelCheque(chequeId);
  }

  if (amount <= 0) {
    notify.error("Enter an amount", "Type a whole number greater than zero.");
    return;
  }

  if (action === "cheque-issue") {
    if (!recipient) {
      notify.error("Enter a recipient", "Type the exact username of the player receiving the cheque.");
      return;
    }
    if (!Number.isSafeInteger(amount) || amount > 1e12) {
      notify.error("Invalid cheque amount", "Enter a whole-dollar amount from $1 to $1 trillion.");
      return;
    }
    if (amount > Number(data.money || 0)) {
      notify.error("Not enough money", "The cheque's face value must be in your wallet.");
      return;
    }
    const tax = Math.round(amount * 7.5) / 100;
    const ok = await confirmDialog({
      title: "Write this cheque?",
      body: `<p><strong>${chequeMoney(amount)}</strong> will leave your wallet for <strong>${escapeHtml(recipient)}</strong> now.</p>
             <p>When cashed, ${chequeMoney(tax)} (7.5%) is removed as tax and the recipient gets <strong>${chequeMoney(amount - tax)}</strong>. You may cancel before it is cashed.</p>`,
      confirmLabel: `Write ${chequeMoney(amount)} cheque`, defaultAction: "cancel", preventEnter: true
    });
    if (ok !== "confirm") return;
    return bankIssueCheque(recipient, amount);
  }

  if (action === "borrow") {
    if (amount > Number(data.available_credit || 0)) {
      notify.error("Over your limit", `You can borrow up to ${money(data.available_credit)} right now.`);
      return;
    }
    const ok = await confirmDialog({
      title: "Take out a loan?",
      body: `<p>Borrow <strong>${money(amount)}</strong> at <strong>${percent(data.loan_apr)}</strong> APR.</p>
             <p>Interest accrues daily and the balance is due within 7 days. Missing the due date charges a late fee and lowers your credit score.</p>`,
      confirmLabel: `Borrow ${money(amount)}`,
      defaultAction: "cancel",
      preventEnter: true
    });
    if (ok !== "confirm") return;
    return bankBorrow(amount);
  }

  if (action === "repay") {
    const pay = Math.min(amount, Number(data.loan_total || 0));
    const ok = await confirmDialog({
      title: "Repay your loan?",
      body: `<p>Pay <strong>${money(pay)}</strong> from your wallet toward the ${money(data.loan_total)} owed.</p>
             <p>Interest is cleared first, then principal. Paying it off on time boosts your credit score.</p>`,
      confirmLabel: `Repay ${money(pay)}`,
      defaultAction: "cancel",
      preventEnter: true
    });
    if (ok !== "confirm") return;
    return bankRepay(amount);
  }

  if (action === "deposit") return bankDeposit(amount);
  if (action === "withdraw") return bankWithdraw(amount);
}

async function refresh() {
  const [{ data: result, error }, chequeResult] = await Promise.all([
    loadBankDashboard(), loadBankCheques(incomingOffset, outgoingOffset)
  ]);
  if (error) {
    $("status").textContent = error.message;
    return;
  }
  data = result;
  cheques = chequeResult.error ? null : chequeResult.data;
  chequeError = chequeResult.error ? "Cheques are unavailable until the bank update is deployed." : null;
  render();
}

document.addEventListener("input", (event) => {
  if (event.target?.id === "chequeAmount") updateChequeQuote();
});

document.addEventListener("click", async (event) => {
  const pageButton = event.target.closest("[data-cheque-page]");
  if (pageButton && !busy) {
    const [direction, step] = pageButton.dataset.chequePage.split("-");
    const delta = step === "next" ? 30 : -30;
    if (direction === "incoming") incomingOffset = Math.max(0, incomingOffset + delta);
    else outgoingOffset = Math.max(0, outgoingOffset + delta);
    await refresh();
    return;
  }
  const button = event.target.closest("[data-action]");
  if (!button || busy) return;
  const action = button.dataset.action;
  const amount = action === "cheque-issue"
    ? Number($("chequeAmount")?.value || 0)
    : readAmount(button.dataset.input);
  const recipient = $("chequeRecipient")?.value.trim() || "";
  const chequeId = button.dataset.chequeId;
  busy = true;
  render();
  try {
    const outcome = await act(action, amount, recipient, chequeId);
    if (outcome === undefined) return; // validation stopped or user cancelled
    if (outcome.error) {
      notify.error("Bank", outcome.error.message);
    } else {
      if (action.startsWith("cheque-")) {
        incomingOffset = 0;
        outgoingOffset = 0;
        const message = {
          "cheque-issue": `Cheque written to ${outcome.data.recipient}.`,
          "cheque-cash": `Cheque cashed for ${chequeMoney(outcome.data.netAmount)} after tax.`,
          "cheque-cancel": `Cheque cancelled; ${chequeMoney(outcome.data.refunded)} returned.`
        }[action];
        notify.success("Bank", message);
      } else if (action === "bankruptcy") {
        data = outcome.data;
        notify.success("Bank", "Debt discharged. Credit reset to 300; borrowing frozen 14 days.");
      } else {
        data = outcome.data;
        const done = { deposit: "Deposited", withdraw: "Withdrew", borrow: "Borrowed", repay: "Repaid" }[action];
        notify.success("Bank", `${done} ${money(amount)}`);
      }
    }
  } finally {
    busy = false;
    await refresh();
  }
});

refresh();
