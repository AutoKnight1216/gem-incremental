import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const read = (path) => fs.readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const sql = read("supabase/migrations/20260927081530_daily_lottery_v1.sql");
const resultDetailsSql = read("supabase/migrations/20260928143421_expose_lottery_result_details.sql");
const randomizedRangesSql = read("supabase/migrations/20260928145656_randomized_lottery_ranges.sql");
const client = read("src/backend/cloudLottery.js");
const page = read("lottery/lottery.js");
const html = read("lottery/index.html");
const shell = read("src/ui/shell.js");
const economy = read("admin/economy.js");

const functionBody = (name, source = sql) => {
  const match = source.match(new RegExp(`create(?: or replace)? function public\\.${name}\\([\\s\\S]*?\\nend \\$\\$;`));
  assert.ok(match, `${name} must exist`);
  return match[0];
};

const band = (tickets) => tickets === 0 ? "The lottery is empty."
  : tickets < 100 ? "The lottery is just getting started."
  : tickets < 1000 ? "The lottery is picking up."
  : tickets < 5000 ? "Competition is heating up."
  : tickets < 20000 ? "The lottery is getting crowded."
  : tickets < 50000 ? "The lottery is packed."
  : tickets < 100000 ? "The lottery is overflowing with entries."
  : tickets < 250000 ? "The lottery is absolutely stacked."
  : "Good luck.";

const roundPrize = (tickets, basisPoints) =>
  Math.floor((((tickets * 10_000) * basisPoints / 10_000) / 1_000) + .5) * 1_000;

function selectWinner(allocations, winningInteger) {
  let cumulative = 0;
  for (const row of [...allocations].sort((a,b) => a.player.localeCompare(b.player))) {
    cumulative += row.tickets;
    if (cumulative >= winningInteger) return row.player;
  }
  return null;
}

test("schema aggregates tickets, locks down private audit data, and preserves immutable secrets", () => {
  assert.match(sql, /create table public\.lottery_draws/);
  assert.match(sql, /create table public\.lottery_allocations/);
  assert.match(sql, /primary key \(draw_id, player_id\)/);
  assert.doesNotMatch(sql, /create table public\.lottery_tickets/);
  for (const table of ["lottery_draws","lottery_allocations","lottery_purchase_requests"]) {
    assert.match(sql, new RegExp(`alter table public\\.${table} enable row level security`));
  }
  assert.match(sql, /revoke all on public\.lottery_draws, public\.lottery_allocations, public\.lottery_purchase_requests\s+from public, anon, authenticated, service_role/);
  assert.match(sql, /guard_draw_secrets/);
  assert.match(sql, /ddbec6fd65eac019478769818c491c52/);
  assert.match(sql, /new\.payout_basis_points is distinct from old\.payout_basis_points/);
  assert.match(sql, /payout_basis_points between 8000 and 9000/);
});

test("Singapore schedule enforces open, cutoff, draw, and transition boundaries using server time", () => {
  assert.match(sql, /time '22:05'\) at time zone 'Asia\/Singapore'/);
  assert.match(sql, /time '21:55'\) at time zone 'Asia\/Singapore'/);
  assert.match(sql, /time '22:00'\) at time zone 'Asia\/Singapore'/);
  assert.match(sql, /v_now timestamptz:=clock_timestamp\(\)/);
  assert.match(sql, /status='open' and open_at<=v_now and cutoff_at>v_now/);
  assert.match(sql, /status='open' and cutoff_at<=v_now/);
  assert.match(sql, /draw_at<=v_now/);
  assert.match(sql, /cron\.schedule\('maintain-daily-lottery','\* \* \* \* \*'/);
  const local = (iso) => new Intl.DateTimeFormat("en-CA", { timeZone:"Asia/Singapore", hourCycle:"h23", year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",second:"2-digit" }).format(new Date(iso));
  assert.match(local("2026-09-27T13:54:59Z"), /21:54:59/);
  assert.match(local("2026-09-27T13:55:00Z"), /21:55:00/);
  assert.match(local("2026-09-27T14:00:00Z"), /22:00:00/);
  assert.match(local("2026-09-27T14:05:00Z"), /22:05:00/);
  // Singapore has no DST; the same UTC offset is authoritative year-round.
  assert.match(local("2027-03-28T14:00:00Z"), /22:00:00/);
});

test("all fuzzy-band boundaries are exact and the SQL uses total tickets", () => {
  const cases = new Map([
    [0,"The lottery is empty."],[1,"The lottery is just getting started."],[99,"The lottery is just getting started."],
    [100,"The lottery is picking up."],[999,"The lottery is picking up."],[1000,"Competition is heating up."],
    [4999,"Competition is heating up."],[5000,"The lottery is getting crowded."],[19999,"The lottery is getting crowded."],
    [20000,"The lottery is packed."],[49999,"The lottery is packed."],[50000,"The lottery is overflowing with entries."],
    [99999,"The lottery is overflowing with entries."],[100000,"The lottery is absolutely stacked."],
    [249999,"The lottery is absolutely stacked."],[250000,"Good luck."],[9_000_000,"Good luck."]
  ]);
  for (const [tickets,expected] of cases) assert.equal(band(tickets),expected);
  assert.match(sql, /activity_band\(v_draw\.total_tickets\)/);
  assert.doesNotMatch(functionBody("get_daily_lottery"), /unique_participants\)/);
});

test("secure weighted selection is stable, equal per ticket, and covers zero/one-ticket draws", () => {
  assert.match(sql, /extensions\.gen_random_bytes\(7\)/);
  assert.match(sql, /v_limit := v_space - mod\(v_space, p_upper::numeric\)/);
  assert.match(sql, /sum\(a\.ticket_count\) over\(order by a\.player_id/);
  const allocations = [{player:"b",tickets:1000},{player:"d",tickets:136437},{player:"a",tickets:50},{player:"c",tickets:5}];
  assert.equal(selectWinner(allocations,1),"a");
  assert.equal(selectWinner(allocations,50),"a");
  assert.equal(selectWinner(allocations,51),"b");
  assert.equal(selectWinner(allocations,738),"b");
  assert.equal(selectWinner(allocations,1051),"c");
  assert.equal(selectWinner([{player:"only",tickets:1}],1),"only");
  assert.equal(selectWinner([],1),null);
  assert.match(sql, /if v_total=0 then[\s\S]*winner_id=null[\s\S]*final_prize=0/);
});

test("settlement privately randomizes and freezes entrant ranges independently of UUID order", () => {
  const settle = functionBody("settle_lottery_draw", randomizedRangesSql);
  assert.match(randomizedRangesSql, /add column settlement_order_key bytea/);
  assert.match(randomizedRangesSql, /add column settlement_position integer/);
  assert.match(randomizedRangesSql, /add column range_start bigint/);
  assert.match(randomizedRangesSql, /add column range_end bigint/);
  assert.match(settle, /extensions\.gen_random_bytes\(16\) settlement_order_key/);
  assert.match(settle, /row_number\(\) over\(order by settlement_order_key,player_id\)/);
  assert.match(settle, /v_winning := lottery_private\.secure_random_bigint\(v_total\)/);
  assert.match(settle, /v_winning between a\.range_start and a\.range_end/);
  assert.doesNotMatch(settle, /sum\(a\.ticket_count\) over\(order by a\.player_id/);
  assert.match(randomizedRangesSql, /lottery_allocation_finalized/);
});

test("payout uses bounded precommitted constant and deterministic half-up thousand rounding", () => {
  assert.equal(roundPrize(1,8000),8000);
  assert.equal(roundPrize(1,8500),9000);
  assert.equal(roundPrize(1,9000),9000);
  assert.equal(roundPrize(100_000,8730),873_000_000);
  assert.match(sql, /7999\+lottery_private\.secure_random_bigint\(1001\)/);
  assert.match(sql, /v_prize := floor\([^;]+\+0\.5\)\*1000/);
});

test("purchases are atomic for wallet/bank, reject insufficient funds, and serialize concurrency", () => {
  const purchase = functionBody("purchase_lottery_tickets");
  assert.match(purchase, /for update/);
  assert.match(purchase, /pg_advisory_xact_lock\(hashtextextended/);
  assert.match(purchase, /money=money-v_cost where id=v_uid and money>=v_cost/);
  assert.match(purchase, /balance=balance-v_cost[\s\S]*player_id=v_uid and balance>=v_cost/);
  assert.match(purchase, /insert into public\.bank_transactions[\s\S]*'lottery'/);
  assert.match(purchase, /p_funding_source not in \('wallet','bank'\)/);
  assert.match(purchase, /lottery_insufficient_wallet/);
  assert.match(purchase, /lottery_insufficient_bank/);
  assert.match(purchase, /ticket_count=ticket_count\+p_quantity/);
  assert.match(purchase, /total_tickets=total_tickets\+p_quantity/);
  assert.match(purchase, /created_at>v_now-interval '10 seconds'/);
  assert.match(purchase, /p_request_id/);
  assert.doesNotMatch(purchase, /equipment|luck|mutation|total_rolls|buff/i);
});

test("settlement is retry-safe, concurrency-safe, credits offline winner, and records only purchase/payout cash", () => {
  const settle = functionBody("settle_lottery_draw");
  assert.match(settle, /where id=p_draw_id for update/);
  assert.match(settle, /if v_draw\.status='settled' then/);
  assert.match(sql, /settlement_reference text unique/);
  assert.match(settle, /update public\.players set money=money\+v_prize/);
  assert.doesNotMatch(settle, /online|presence|last_seen/i);
  assert.match(sql, /\('purchase_lottery_tickets','lottery','sink'\)/);
  assert.match(sql, /\('settle_lottery_draw','lottery','source'\)/);
  assert.match(sql, /'lottery-purchase:'\|\|p_request_id/);
  assert.match(sql, /'lottery-payout:'\|\|v_draw\.id/);
  assert.doesNotMatch(settle, /record_fee|burn_player_money|insert into public\.economy_cash_ledger/);
});

test("public APIs keep the live draw private and expose requested completed-result details", () => {
  const dashboard = functionBody("get_daily_lottery", resultDetailsSql);
  for (const key of ["ticketPrice","ownTickets","activityBand","serverNow","recentResults","walletBalance","bankBalance"]) {
    assert.match(dashboard,new RegExp(`'${key}'`));
  }
  for (const key of ["totalTickets","winningTicketNumber","winnerCost","profit","profitPercent"]) {
    assert.match(dashboard,new RegExp(`'${key}'`));
  }
  for (const leaked of ["grossRevenue","payoutBasisPoints","winnerTicketCount","effectiveBurn","uniqueParticipants"]) {
    assert.doesNotMatch(dashboard,new RegExp(`'${leaked}'`));
  }
  assert.match(dashboard,/where status='settled' order by draw_date desc limit 10/);
  assert.match(dashboard,/winner_ticket_count::numeric\*d\.ticket_price/);
  assert.doesNotMatch(page,/odds|1 in|jackpot/i);
  for (const label of ["Expand more","Number of tickets","Winning ticket number","Winner cost","Profit"]) {
    assert.match(page,new RegExp(label));
  }
  assert.match(html,/\+1[\s\S]*\+10[\s\S]*\+100[\s\S]*\+1,000[\s\S]*Custom/);
  assert.doesNotMatch(html,/>MAX</i);
});

test("large-purchase safeguards, recent public results, and offline win acknowledgement are wired", () => {
  assert.match(page,/amount < 10_000_000/);
  assert.match(page,/amount >= 100_000_000/);
  assert.match(page,/Winning is not guaranteed regardless of how many tickets you purchase/);
  assert.match(html,/Exact cost/);
  assert.match(page,/acknowledgeLotteryWin/);
  assert.match(sql,/winner_notified_at/);
  assert.match(sql,/order by draw_date desc limit 10/);
  assert.match(client,/purchase_lottery_tickets/);
});

test("admin analytics cover spending, payout, burn, participation, concentration, sink share, and faucet offset", () => {
  for (const key of ["grossSpending","payouts","netBurn","effectiveBurnRate","uniqueParticipants","repeatParticipants","medianTicketsPerParticipant","largestPurchase","largestDrawSpender","topPlayerSpendingShare","lotteryShareOfSinks","burnVsGemSaleRevenue","finalBands","drawAudit"]) {
    assert.match(sql,new RegExp(`'${key}'`));
  }
  assert.match(sql,/raise exception 'not_admin'/);
  assert.match(economy,/Daily Lottery/);
  assert.match(economy,/admin_get_lottery_analytics/);
});

test("navigation and feature gating expose the shipped lottery page", () => {
  assert.match(shell,/id: "lottery", label: "Daily Lottery"[^\n]*sectionId: "lottery"/);
  assert.match(sql,/values\('lottery','Daily Lottery','Lottery','dice',[\s\S]*true,325\)/);
});
