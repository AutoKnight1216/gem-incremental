import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import { PGlite } from "@electric-sql/pglite";

const migration = fs.readFileSync(new URL("../supabase/migrations/20260927081530_daily_lottery_v1.sql", import.meta.url), "utf8")
  // PGlite does not bundle pgcrypto. A deterministic byte source lets the
  // migration's PostgreSQL transaction/RPC logic run locally; the static suite
  // separately requires the production pgcrypto call and rejection sampling.
  .replace("create extension if not exists pgcrypto with schema extensions;", "")
  .replace(/do \$capture_cash_guard\$[\s\S]*?end \$capture_cash_guard\$;/, "");
const resultDetailsMigration = fs.readFileSync(new URL("../supabase/migrations/20260928143421_expose_lottery_result_details.sql", import.meta.url), "utf8");
const randomizedRangesMigration = fs.readFileSync(new URL("../supabase/migrations/20260928145656_randomized_lottery_ranges.sql", import.meta.url), "utf8");
const prizePoolMigration = fs.readFileSync(new URL("../supabase/migrations/20260930135909_expose_lottery_prize_pool.sql", import.meta.url), "utf8");

const PLAYER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";

async function setup() {
  const db = new PGlite();
  await db.exec(`
    create role anon;
    create role authenticated;
    create role service_role;
    create schema auth;
    create schema extensions;
    create schema economy_private;
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
    $$;
    create function extensions.gen_random_bytes(integer) returns bytea language sql volatile as $$
      select decode(substr(md5(random()::text)||md5(random()::text),1,$1*2),'hex')
    $$;
    create table auth.users(id uuid primary key);
    create table public.players(id uuid primary key references auth.users(id),username text not null,money numeric not null default 0,lifetime_earnings numeric not null default 0);
    create table public.bank_accounts(player_id uuid primary key references auth.users(id),balance numeric not null default 0,loan_principal numeric not null default 0,loan_interest_accrued numeric not null default 0,credit_score integer not null default 600,updated_at timestamptz default now());
    create table public.bank_transactions(id bigint generated always as identity primary key,player_id uuid,kind text,amount numeric,balance_after numeric,loan_after numeric,credit_after integer,memo text,created_at timestamptz default now());
    create table public.admins(user_id uuid primary key);
    create table public.system_account_exclusions(player_id uuid primary key,exclude_from_economy boolean not null default false);
    create table public.game_section_settings(id text primary key,label text,short_label text,icon text,description text,enabled boolean,sort_order integer);
    create table public.economy_cash_ledger(
      id bigint generated always as identity primary key,created_at timestamptz not null default statement_timestamp(),
      transaction_id bigint not null default txid_current(),player_id uuid,account text not null,amount numeric not null,
      direction text not null,category text not null,subcategory text not null,reference text,metadata jsonb not null default '{}'
    );
    create table economy_private.cash_paths(function_name text primary key,category text not null,direction text);
    create function economy_private.capture_cash() returns trigger language plpgsql as $$ begin return null; end $$;
    create trigger economy_wallet_update after update of money on public.players for each row execute function economy_private.capture_cash('wallet','money','id');
    create trigger economy_bank_update after update of balance on public.bank_accounts for each row execute function economy_private.capture_cash('bank','balance','player_id');
    create function public.bank_touch(p_uid uuid) returns void language plpgsql security definer as $$
    begin insert into public.bank_accounts(player_id) values(p_uid) on conflict(player_id) do nothing; end $$;
    insert into auth.users values('${PLAYER}'),('${OTHER}');
    insert into public.players(id,username,money,lifetime_earnings) values
      ('${PLAYER}','Tester',1000000,0),('${OTHER}','OfflineWinner',0,0);
    insert into public.bank_accounts(player_id,balance) values('${PLAYER}',500000);
    select set_config('request.jwt.claim.sub','${PLAYER}',false);
  `);
  await db.exec(migration);
  await db.exec(resultDetailsMigration);
  await db.exec(randomizedRangesMigration);
  await db.exec(prizePoolMigration);
  return db;
}

test("live payable pool and completed result economics are public without exposing current tax", async () => {
  const db = await setup();
  try {
    await db.exec(`delete from public.lottery_draws;
      insert into public.lottery_draws(id,draw_date,open_at,cutoff_at,draw_at,next_open_at,status,payout_basis_points,total_tickets,gross_revenue)
      values('TEST-LIVE',current_date,now()-interval '1 hour',now()+interval '1 hour',now()+interval '2 hours',now()+interval '2 hours 5 minutes','open',8500,123,1230000);
      insert into public.lottery_draws(id,draw_date,open_at,cutoff_at,draw_at,next_open_at,status,payout_basis_points,
        total_tickets,unique_participants,gross_revenue,winning_integer,winner_id,winner_username,winner_ticket_count,
        final_prize,effective_burn,final_activity_band,settlement_reference,settled_at)
      values('TEST-HISTORY',current_date-1,now()-interval '2 days',now()-interval '1 day 10 minutes',now()-interval '1 day 5 minutes',now()-interval '1 day',
        'settled',8500,42,3,420000,17,'${OTHER}','OfflineWinner',5,357000,63000,'The lottery is just getting started.','lottery-settlement:TEST-HISTORY',now()-interval '1 day');`);
    const payload = (await db.query("select public.get_daily_lottery() result")).rows[0].result;
    assert.equal(payload.drawId,"TEST-LIVE");
    assert.equal(Number(payload.prizePool),1046000);
    assert.equal(Object.hasOwn(payload,"totalTickets"),false);
    assert.equal(Object.hasOwn(payload,"winningTicketNumber"),false);
    assert.equal(Object.hasOwn(payload,"taxPercent"),false);
    assert.equal(Object.hasOwn(payload,"activityBand"),false);
    const result = payload.recentResults[0];
    assert.equal(Number(result.totalTickets),42);
    assert.equal(Number(result.winningTicketNumber),17);
    assert.equal(Number(result.winnerCost),50000);
    assert.equal(Number(result.taxPercent),15);
    assert.equal(Number(result.profit),307000);
    assert.equal(Number(result.profitPercent),614);
  } finally {
    await db.close();
  }
});

test("migration parses and wallet/bank purchases commit allocations, balances, and one sink entry each", async () => {
  const db = await setup();
  try {
    await db.exec(`delete from public.lottery_draws;
      insert into public.lottery_draws(id,draw_date,open_at,cutoff_at,draw_at,next_open_at,status,payout_basis_points)
      values('TEST-OPEN',current_date,now()-interval '1 hour',now()+interval '1 hour',now()+interval '2 hours',now()+interval '2 hours 5 minutes','open',8500);`);
    const wallet = (await db.query("select public.purchase_lottery_tickets(10,'wallet','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') result")).rows[0].result;
    assert.equal(wallet.ok,true);
    assert.equal(Number(wallet.cost),100000);
    const bank = (await db.query("select public.purchase_lottery_tickets(5,'bank','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') result")).rows[0].result;
    assert.equal(bank.ok,true);
    assert.equal(Number(bank.ownTickets),15);
    const balances = (await db.query(`select p.money,b.balance,a.ticket_count,d.total_tickets,d.unique_participants
      from public.players p join public.bank_accounts b on b.player_id=p.id
      join public.lottery_allocations a on a.player_id=p.id
      join public.lottery_draws d on d.id=a.draw_id where p.id='${PLAYER}'`)).rows[0];
    assert.equal(Number(balances.money),900000);
    assert.equal(Number(balances.balance),450000);
    assert.equal(Number(balances.ticket_count),15);
    assert.equal(Number(balances.total_tickets),15);
    assert.equal(balances.unique_participants,1);
    const ledger = (await db.query("select account,amount,direction,category,reference,metadata->>'drawId' draw_id from public.economy_cash_ledger order by id")).rows;
    assert.deepEqual(ledger.map(row=>[row.account,Number(row.amount),row.direction,row.category,row.draw_id]),[
      ["wallet",-100000,"sink","lottery","TEST-OPEN"],
      ["bank",-50000,"sink","lottery","TEST-OPEN"]
    ]);
    assert.match(ledger[0].reference,/^lottery-purchase:/);

    const before = (await db.query("select balance from public.bank_accounts where player_id=$1",[PLAYER])).rows[0].balance;
    const rejected = (await db.query("select public.purchase_lottery_tickets(1000,'bank','cccccccc-cccc-4ccc-8ccc-cccccccccccc') result")).rows[0].result;
    assert.equal(rejected.ok,false);
    assert.equal(rejected.code,"lottery_insufficient_bank");
    const after = (await db.query("select balance from public.bank_accounts where player_id=$1",[PLAYER])).rows[0].balance;
    assert.equal(after,before);
  } finally {
    await db.close();
  }
});

test("settlement handles zero/one-ticket draws, pays offline once, and never creates a second burn entry", async () => {
  const db = await setup();
  try {
    await db.exec(`delete from public.lottery_draws;
      insert into public.lottery_draws(id,draw_date,open_at,cutoff_at,draw_at,next_open_at,status,payout_basis_points,total_tickets,unique_participants,gross_revenue)
      values
      ('TEST-ZERO',current_date-1,now()-interval '1 day',now()-interval '10 minutes',now()-interval '5 minutes',now()-interval '1 minute','locked',8000,0,0,0),
      ('TEST-ONE',current_date,now()-interval '1 day',now()-interval '10 minutes',now()-interval '5 minutes',now()-interval '1 minute','open',8500,1,1,10000);
      insert into public.lottery_allocations(draw_id,player_id,ticket_count,purchase_total)
      values('TEST-ONE','${OTHER}',1,10000);
      update public.lottery_draws set status='locked' where id='TEST-ONE';`);
    const zero = (await db.query("select public.settle_lottery_draw('TEST-ZERO') result")).rows[0].result;
    assert.equal(zero.winner,null);
    assert.equal(Number(zero.prize),0);
    const settlementRetries = await Promise.all([
      db.query("select public.settle_lottery_draw('TEST-ONE') result"),
      db.query("select public.settle_lottery_draw('TEST-ONE') result")
    ]);
    const one = settlementRetries.map(result=>result.rows[0].result).find(result=>result.winnerId);
    assert.equal(one.winnerId,OTHER);
    assert.equal(Number(one.prize),9000);
    const paid = (await db.query("select money from public.players where id=$1",[OTHER])).rows[0].money;
    assert.equal(Number(paid),9000);
    await db.query("select public.settle_lottery_draw('TEST-ONE')");
    const paidAgain = (await db.query("select money from public.players where id=$1",[OTHER])).rows[0].money;
    assert.equal(Number(paidAgain),9000);
    const ledger = (await db.query("select amount,direction,category,reference from public.economy_cash_ledger order by id")).rows;
    assert.equal(ledger.length,1);
    assert.equal(Number(ledger[0].amount),9000);
    assert.equal(ledger[0].direction,"source");
    assert.equal(ledger[0].category,"lottery");
    assert.equal(ledger[0].reference,"lottery-payout:TEST-ONE");
    const audit = (await db.query("select winning_integer,winner_ticket_count,final_prize,effective_burn,final_activity_band,settlement_reference from public.lottery_draws where id='TEST-ONE'")).rows[0];
    assert.equal(Number(audit.winning_integer),1);
    assert.equal(Number(audit.winner_ticket_count),1);
    assert.equal(Number(audit.final_prize),9000);
    assert.equal(Number(audit.effective_burn),1000);
    assert.equal(audit.final_activity_band,"The lottery is just getting started.");
  } finally {
    await db.close();
  }
});

test("settlement freezes a private random order with exact contiguous ranges", async () => {
  const db = await setup();
  try {
    const THIRD = "33333333-3333-4333-8333-333333333333";
    await db.exec(`delete from public.lottery_draws;
      insert into auth.users values('${THIRD}');
      insert into public.players(id,username,money,lifetime_earnings) values('${THIRD}','ThirdEntrant',0,0);
      insert into public.lottery_draws(id,draw_date,open_at,cutoff_at,draw_at,next_open_at,status,payout_basis_points)
      values('TEST-RANGES',current_date,now()-interval '1 day',now()-interval '10 minutes',now()-interval '5 minutes',now()-interval '1 minute','locked',8500);
      update public.lottery_draws set status='open' where id='TEST-RANGES';
      insert into public.lottery_allocations(draw_id,player_id,ticket_count,purchase_total) values
        ('TEST-RANGES','${PLAYER}',3,30000),
        ('TEST-RANGES','${OTHER}',5,50000),
        ('TEST-RANGES','${THIRD}',7,70000);
      update public.lottery_draws set status='locked' where id='TEST-RANGES';`);

    await db.query("select public.settle_lottery_draw('TEST-RANGES')");
    const ranges = (await db.query(`select player_id,settlement_order_key,settlement_position,range_start,range_end,ticket_count,finalized_at
      from public.lottery_allocations where draw_id='TEST-RANGES' order by settlement_position`)).rows;
    assert.equal(ranges.length,3);
    assert.ok(ranges.every(row => row.settlement_order_key && row.finalized_at));
    assert.deepEqual(ranges.map(row => Number(row.settlement_position)),[1,2,3]);
    assert.equal(Number(ranges[0].range_start),1);
    assert.equal(Number(ranges.at(-1).range_end),15);
    for (let index=0; index<ranges.length; index+=1) {
      const row = ranges[index];
      assert.equal(Number(row.range_end)-Number(row.range_start)+1,Number(row.ticket_count));
      if (index>0) assert.equal(Number(row.range_start),Number(ranges[index-1].range_end)+1);
    }
    const draw = (await db.query("select winning_integer,winner_id from public.lottery_draws where id='TEST-RANGES'")).rows[0];
    const winnerRange = ranges.find(row => row.player_id===draw.winner_id);
    assert.ok(Number(draw.winning_integer)>=Number(winnerRange.range_start));
    assert.ok(Number(draw.winning_integer)<=Number(winnerRange.range_end));
    await assert.rejects(
      db.query("update public.lottery_allocations set range_start=range_start+1 where draw_id='TEST-RANGES'"),
      /lottery_allocation_finalized/
    );
  } finally {
    await db.close();
  }
});

test("concurrent purchase calls preserve totals and identical retry keys charge only once", async () => {
  const db = await setup();
  try {
    await db.exec(`delete from public.lottery_draws;
      update public.players set money=5000000 where id='${PLAYER}';
      insert into public.lottery_draws(id,draw_date,open_at,cutoff_at,draw_at,next_open_at,status,payout_basis_points)
      values('TEST-CONCURRENT',current_date,now()-interval '1 hour',now()+interval '1 hour',now()+interval '2 hours',now()+interval '2 hours 5 minutes','open',8500);`);
    const ids = [1,2,3,4,5,6].map(n => `${String(n).padStart(8,"0")}-0000-4000-8000-000000000000`);
    const results = await Promise.all(ids.map(id => db.query("select public.purchase_lottery_tickets(1,'wallet',$1::uuid) result",[id])));
    assert.ok(results.every(result => result.rows[0].result.ok));
    const retryId = "99999999-9999-4999-8999-999999999999";
    const retries = await Promise.all([
      db.query("select public.purchase_lottery_tickets(2,'wallet',$1::uuid) result",[retryId]),
      db.query("select public.purchase_lottery_tickets(2,'wallet',$1::uuid) result",[retryId])
    ]);
    assert.deepEqual(retries[0].rows[0].result,retries[1].rows[0].result);
    const state = (await db.query(`select d.total_tickets,a.ticket_count,p.money,
      (select count(*) from public.economy_cash_ledger where category='lottery') ledger_entries
      from public.lottery_draws d join public.lottery_allocations a on a.draw_id=d.id
      join public.players p on p.id=a.player_id where d.id='TEST-CONCURRENT'`)).rows[0];
    assert.equal(Number(state.total_tickets),8);
    assert.equal(Number(state.ticket_count),8);
    assert.equal(Number(state.money),4_920_000);
    assert.equal(Number(state.ledger_entries),7);
  } finally {
    await db.close();
  }
});
