import { supabase } from "./supabase.js";

const MESSAGES = {
  not_authenticated: "Sign in to enter the daily lottery.",
  lottery_closed: "Entries are closed. You were not charged.",
  lottery_invalid_quantity: "Enter a valid whole number of tickets.",
  lottery_invalid_funding_source: "Choose your wallet or bank balance.",
  lottery_insufficient_wallet: "Your wallet cannot cover the full purchase. You were not charged.",
  lottery_insufficient_bank: "Your bank balance cannot cover the full purchase. You were not charged.",
  lottery_rate_limited: "Too many purchase attempts. Wait a moment and try again.",
  lottery_unavailable: "The next lottery is being prepared. Try again shortly."
};

function normalise(error) {
  if (!error) return null;
  const code = Object.keys(MESSAGES).find((value) => error.message?.includes(value)) ?? error.code;
  return { code, message: MESSAGES[code] ?? "The lottery request could not be completed." };
}

async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  return { data, error: normalise(error) };
}

export const loadDailyLottery = () => rpc("get_daily_lottery");

export const purchaseLotteryTickets = (quantity, fundingSource, requestId = crypto.randomUUID()) =>
  rpc("purchase_lottery_tickets", {
    p_quantity: quantity,
    p_funding_source: fundingSource,
    p_request_id: requestId
  });

export const acknowledgeLotteryWin = (drawId) =>
  rpc("acknowledge_lottery_win", { p_draw_id: drawId });
