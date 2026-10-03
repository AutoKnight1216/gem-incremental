import { supabase } from "../backend/supabase.js";
import { adminRequest } from "../backend/cloudAdmin.js";
import { escapeHtml } from "./format.js";

const POLL_MS = 10_000;
let mounted = false;

function durationLabel(milliseconds) {
  const totalSeconds = Math.max(0, Math.ceil(milliseconds / 1000));
  const days = Math.floor(totalSeconds / 86400);
  const hours = Math.floor((totalSeconds % 86400) / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (days) return `${days}d ${hours}h ${minutes}m`;
  if (hours) return `${hours}h ${minutes}m ${seconds}s`;
  return `${minutes}m ${seconds}s`;
}

function maintenanceMarkup(status, serverOffset) {
  const endsAt = new Date(status.endsAt);
  const remaining = endsAt.getTime() - (Date.now() + serverOffset);
  return `
    <div class="maintenance-overlay__card">
      <span class="maintenance-overlay__icon" aria-hidden="true">◆</span>
      <p class="maintenance-overlay__eyebrow">Scheduled update</p>
      <h1>Game update in progress</h1>
      <p>${escapeHtml(status.message || "The game is temporarily offline while we install an update.")}</p>
      <div class="maintenance-overlay__time">
        <span>Expected back</span>
        <strong>${escapeHtml(endsAt.toLocaleString())}</strong>
        <small data-maintenance-countdown>${escapeHtml(durationLabel(remaining))} remaining</small>
      </div>
      <p class="maintenance-overlay__hint">This page checks automatically. You can leave it open.</p>
    </div>`;
}

export function mountMaintenanceMode({ page } = {}) {
  if (mounted) return;
  mounted = true;

  let serverOffset = 0;
  let latestStatus = null;
  let adminBypass = page === "admin";
  let adminChecked = adminBypass;
  let countdownTimer = null;

  const notice = document.createElement("aside");
  notice.className = "maintenance-notice";
  notice.hidden = true;
  notice.setAttribute("role", "status");
  notice.setAttribute("aria-live", "polite");
  document.body.appendChild(notice);

  const overlay = document.createElement("div");
  overlay.className = "maintenance-overlay";
  overlay.hidden = true;
  overlay.setAttribute("role", "alertdialog");
  overlay.setAttribute("aria-modal", "true");
  overlay.setAttribute("aria-labelledby", "maintenanceTitle");
  document.body.appendChild(overlay);

  const clearCountdown = () => {
    if (countdownTimer) clearInterval(countdownTimer);
    countdownTimer = null;
  };

  const render = () => {
    clearCountdown();
    const now = Date.now() + serverOffset;

    if (!latestStatus || latestStatus.phase === "inactive") {
      notice.hidden = true;
      overlay.hidden = true;
      document.documentElement.classList.remove("maintenance-active");
      return;
    }

    if (latestStatus.phase === "scheduled") {
      overlay.hidden = true;
      document.documentElement.classList.remove("maintenance-active");
      const updateNotice = () => {
        const remaining = new Date(latestStatus.startsAt).getTime() - (Date.now() + serverOffset);
        notice.innerHTML = `<strong>Game shutting down for an update</strong><span>${escapeHtml(latestStatus.message)} Shutdown begins in <b>${escapeHtml(durationLabel(remaining))}</b>.</span>`;
        if (remaining <= 0) refresh();
      };
      notice.hidden = false;
      updateNotice();
      countdownTimer = setInterval(updateNotice, 1000);
      return;
    }

    if (adminBypass) {
      overlay.hidden = true;
      document.documentElement.classList.remove("maintenance-active");
      notice.hidden = false;
      notice.innerHTML = `<strong>Maintenance is active</strong><span>Players are blocked until ${escapeHtml(new Date(latestStatus.endsAt).toLocaleString())}. Admin access remains available.</span>`;
      return;
    }

    notice.hidden = true;
    overlay.hidden = false;
    overlay.innerHTML = maintenanceMarkup(latestStatus, serverOffset).replace("<h1>", '<h1 id="maintenanceTitle">');
    document.documentElement.classList.add("maintenance-active");
    const updateCountdown = () => {
      const remaining = new Date(latestStatus.endsAt).getTime() - (Date.now() + serverOffset);
      const element = overlay.querySelector("[data-maintenance-countdown]");
      if (element) element.textContent = `${durationLabel(remaining)} remaining`;
      if (remaining <= 0) refresh();
    };
    updateCountdown();
    countdownTimer = setInterval(updateCountdown, 1000);
  };

  const checkAdmin = async () => {
    if (adminChecked) return;
    adminChecked = true;
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session?.user) return;
    const { data } = await adminRequest("whoami");
    adminBypass = data?.isAdmin === true;
  };

  const refresh = async () => {
    const { data, error } = await supabase.rpc("get_game_maintenance_status");
    if (error || !data) return;
    latestStatus = data;
    const serverNow = new Date(data.serverNow).getTime();
    if (Number.isFinite(serverNow)) serverOffset = serverNow - Date.now();
    if (data.phase === "active") await checkAdmin();
    render();
  };

  refresh();
  setInterval(refresh, POLL_MS);
}
