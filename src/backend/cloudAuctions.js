import { supabase } from "./supabase.js";

// Auction reads are public table reads. Every mutation is an authenticated,
// server-authoritative RPC that re-checks ownership, balances and timing while
// holding the auction row lock.

const CREATE_MESSAGES = {
  not_authenticated: "You need to be signed in to create an auction.",
  invalid_price: "Enter a valid starting bid.",
  invalid_duration: "Choose a supported auction duration.",
  invalid_quantity: "Enter a valid item quantity.",
  invalid_reference_value: "This lot does not have a positive reference value.",
  too_many_listings: "You can have at most 3 auctions at once — wait for some to close.",
  gem_unavailable: "One of those gems is locked or no longer in your inventory.",
  potion_unavailable: "You do not have that many of one of those consumables.",
  empty_lot: "Add at least one item to the lot first.",
  lot_too_large: "A lot can hold at most 25 different items.",
  not_auctionable: "That item cannot be auctioned.",
  consumable_not_market_priced: "That consumable does not have a market reference value yet.",
  start_bid_below_minimum: "The starting bid is below 0.5× the lot reference value.",
  start_bid_above_maximum: "The starting bid is above 10× the lot reference value.",
  not_enough_money_for_listing_fee: "You cannot afford the non-refundable listing fee."
};

const BID_MESSAGES = {
  not_authenticated: "You need to be signed in to bid.",
  invalid_bid: "Enter a valid bid.",
  auction_not_found: "That auction no longer exists.",
  auction_closed: "That auction has already closed.",
  auction_reference_missing: "This legacy listing cannot accept bids.",
  cannot_bid_own: "You cannot bid on your own auction.",
  consecutive_bid_not_allowed: "Another player must bid before you can bid again.",
  bid_cooldown: "You must wait 1 hour after your last bid on this auction.",
  bid_too_low: "That bid is below the minimum allowed next bid.",
  bid_too_high: "That bid is above the maximum allowed next bid.",
  not_enough_money: "You cannot afford that bid."
};

const CANCEL_MESSAGES = {
  not_authenticated: "You need to be signed in.",
  auction_not_found: "That auction no longer exists.",
  not_your_auction: "That is not your auction.",
  auction_closed: "That auction has already closed.",
  has_bids: "An auction cannot be cancelled after its first bid."
};

function friendly(error, table) {
  const raw = String(error?.message ?? "");
  const code = Object.keys(table).find((key) => raw.includes(key));
  return { code: code ?? null, message: table[code] ?? "Something went wrong. Try again." };
}

export async function settleDueAuctions() {
  const { error } = await supabase.rpc("settle_due_auctions");
  if (error) console.warn("settle_due_auctions failed:", error.message);
}

export async function loadActiveAuctions() {
  const { data, error } = await supabase
    .from("auctions").select("*").eq("status", "active")
    .order("ends_at", { ascending: true }).limit(200);
  if (error) { console.error("Failed to load auctions:", error); return []; }
  return Array.isArray(data) ? data : [];
}

export async function loadMyAuctions() {
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return [];
  const { data, error } = await supabase
    .from("auctions").select("*").eq("seller_id", user.id)
    .order("created_at", { ascending: false }).limit(100);
  if (error) { console.error("Failed to load your auctions:", error); return []; }
  return Array.isArray(data) ? data : [];
}

export async function createAuctionLot(items, startingBid, durationHours) {
  const payload = (Array.isArray(items) ? items : []).map((item) =>
    item.type === "potion"
      ? { type: "potion", consumable_id: item.consumableId, quantity: Number(item.quantity) }
      : { type: "gem", id: Number(item.id) }
  );
  const { data, error } = await supabase.rpc("create_auction_lot", {
    p_items: payload,
    p_start_price: Number(startingBid),
    p_duration_hours: Number(durationHours)
  });
  if (error) return { error: friendly(error, CREATE_MESSAGES) };
  return { data: { auctionId: data } };
}

export async function placeBid(auctionId, amount) {
  const { data, error } = await supabase.rpc("place_bid", {
    p_auction_id: Number(auctionId),
    p_amount: Number(amount)
  });
  if (error) return { error: friendly(error, BID_MESSAGES) };
  return { data: data ?? null };
}

export async function cancelAuction(auctionId) {
  const { data, error } = await supabase.rpc("cancel_auction", { p_auction_id: Number(auctionId) });
  if (error) return { error: friendly(error, CANCEL_MESSAGES) };
  return { data: data ?? null };
}
