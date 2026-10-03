import assert from "node:assert/strict";
import fs from "node:fs";

const read = (path) => fs.readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const sql = read("supabase/migrations/20261003143000_bank_cheques.sql");
const client = read("src/backend/cloudBank.js");
const page = read("bank/bank.js");
const html = read("bank/index.html");

const functionBody = (name) => {
  const match = sql.match(new RegExp(`create function public\\.${name}\\([\\s\\S]*?\\n\\$\\$;`, "i"));
  assert.ok(match, `${name} must be defined`);
  return match[0];
};

assert.match(sql, /create table public\.bank_cheques/);
assert.match(sql, /alter table public\.bank_cheques enable row level security/);
assert.match(sql, /revoke all on public\.bank_cheques from public, anon, authenticated/);
assert.match(sql, /check \(face_amount = tax_amount \+ net_amount\)/);
assert.match(sql, /status in \('pending','cashed','cancelled'\)/);
assert.match(sql, /'bank_issue_cheque', 'cheque_escrow', 'transfer'/);
assert.match(sql, /'bank_cash_cheque', 'cheque_escrow', 'transfer'/);
assert.match(sql, /'bank_cancel_cheque', 'cheque_escrow', 'transfer'/);
assert.match(sql, /create function public\.bank_list_cheques\(p_incoming_offset integer default 0, p_outgoing_offset integer default 0\)/);
assert.match(sql, /limit 31 offset v_incoming_offset/);
assert.match(sql, /limit 31 offset v_outgoing_offset/);

for (const name of ["bank_list_cheques", "bank_issue_cheque", "bank_cash_cheque", "bank_cancel_cheque"]) {
  const body = functionBody(name);
  assert.match(body, /security definer set search_path = ''/);
  assert.match(body, /auth\.uid\(\)/);
  assert.match(sql, new RegExp(`grant execute on function public\\.${name}\\([^)]*\\) to authenticated`));
}

const issue = functionBody("bank_issue_cheque");
assert.match(issue, /array_length\(v_matches, 1\) > 1/);
assert.match(issue, /v_recipient = v_uid/);
assert.match(issue, /v_tax := round\(v_face \* 0\.075, 2\)/);
assert.match(issue, /update public\.players set money = money - v_face::double precision\s+where id = v_uid and money >= v_face::double precision/);
assert.match(issue, /insert into public\.bank_cheques/);
assert.match(issue, /v_pending >= 20 then raise exception 'bank_cheque_limit'/);
assert.match(issue, /'clearing', v_face, 'transfer', 'cheque_escrow', 'fund'/);

const cash = functionBody("bank_cash_cheque");
const cancel = functionBody("bank_cancel_cheque");
for (const body of [cash, cancel]) {
  assert.match(body, /for update/);
  assert.match(body, /status <> 'pending'/);
}
assert.match(cash, /recipient_id = v_uid/);
assert.match(cash, /money = money \+ v_cheque\.net_amount::double precision/);
assert.match(cash, /'clearing', -v_cheque\.face_amount, 'transfer', 'cheque_escrow', 'release'/);
assert.match(cash, /'sink', 'cheque_tax'/);
assert.match(cancel, /sender_id = v_uid/);
assert.match(cancel, /money = money \+ v_cheque\.face_amount::double precision/);
assert.match(cancel, /'clearing', -v_cheque\.face_amount, 'transfer', 'cheque_escrow', 'refund'/);
assert.doesNotMatch(cancel, /'sink', 'cheque_tax'/);

assert.match(client, /bankIssueCheque = \(username, amount\) => rpc\("bank_issue_cheque"/);
assert.match(client, /bankCashCheque = \(id\) => rpc\("bank_cash_cheque"/);
assert.match(client, /bankCancelCheque = \(id\) => rpc\("bank_cancel_cheque"/);
assert.match(page, /data-action="cheque-issue"/);
assert.match(page, /data-action="cheque-\$\{incoming \? "cash" : "cancel"\}"/);
assert.match(page, /7\.5% is removed as tax/);
assert.match(page, /incomingPage\.slice\(0, 30\)/);
assert.match(html, /id="cheques"/);

for (const amount of [1, 10, 100, 1000, 1000000]) {
  const tax = Math.round(amount * 7.5) / 100;
  assert.equal(Number((amount - tax + tax).toFixed(2)), amount);
}
assert.equal(Math.round(100 * 7.5) / 100, 7.5);

console.log("bank-cheques-test passed");
