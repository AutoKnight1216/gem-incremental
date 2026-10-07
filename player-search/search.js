import { supabase } from "../src/backend/supabase.js";
import {
ensurePlayerAuth,
isSignInRequired,
SIGN_IN_REQUIRED_MESSAGE,
} from "../src/backend/auth.js";

const form = document.getElementById("searchForm");
const input = document.getElementById("user");
const button = document.getElementById("search");
const result = document.getElementById("searchResult");

function escapeHtml(value) {
return String(value ?? "")
.replaceAll("&", "&")
.replaceAll("<", "<")
.replaceAll(">", ">")
.replaceAll('"', `"`)
.replaceAll("'", "'");
}

function showMessage(title, message) {
result.innerHTML = `     <div class="player-result">       <strong>${escapeHtml(title)}</strong>       <span>${escapeHtml(message)}</span>     </div>
  `;

result.hidden = false;
}


  input.addEventListener("input", () => {
  input.value = input.value.replace(/[^A-Za-z0-9_-]/g, "");
  });

  form.addEventListener("submit", async (event) => {
  event.preventDefault();

console.log("Search form submitted.");

const username = input.value.trim();

if (!username) {
return;
}

button.disabled = true;
button.textContent = "Searching…";
result.hidden = true;

try {
console.log("Searching for:", username);

const { data, error } = await supabase
  .from("players")
  .select("id, username")
  .ilike("username", username)
  .limit(10);

console.log("Supabase result:", {
  data,
  error,
});

if (error) {
  console.error("Supabase error:", error);

  showMessage(
    "Search error",
    error.message || "Supabase returned an error."
  );

  return;
}

if (!data || data.length === 0) {
  showMessage(
    "Player not found",
    `No player named "${username}" was found.`
  );

  return;
}

result.innerHTML = data
  .map(
    (player) => `
      <div class="player-result">
        <strong>${escapeHtml(player.username)}</strong>
        <a href="https://gemincremental.com/user/${escapeHtml(player.id)}"><span>Profile</span></a>
      </div>
    `
  )
  .join("");

result.hidden = false;

console.log("Players found:", data);

input.value = "";


} catch (error) {
console.error("Unexpected error:", error);


showMessage(
  "Something went wrong",
  error.message || "An unexpected error occurred."
);


} finally {
button.disabled = false;
button.textContent = "Search";
}
});

/*

* Authentication happens after the page has initialized.
  */
  async function authenticate() {
  try {
  const authUser = await ensurePlayerAuth();

  if (!authUser) {
  console.error(
  isSignInRequired()
  ? SIGN_IN_REQUIRED_MESSAGE
  : "Could not sign you in."
  );

  return;
  }

  console.log("Signed in:", authUser);
  } catch (error) {
  console.error("Authentication error:", error);
  }
  }

authenticate();
