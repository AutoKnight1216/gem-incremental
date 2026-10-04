import { mountShell } from '../src/ui/shell.js';
import { escapeHtml } from '../src/ui/format.js';
import { ensurePlayerAuth } from '../src/backend/auth.js';
import { loadCosmeticStore, purchaseCosmetic, createFacetClaimCode, saveCosmeticLoadout } from '../src/backend/cloudCosmeticStore.js';
import { COSMETIC_COLLECTIONS, COSMETIC_ITEMS, FACET_PACKS, STORE_SECTIONS, collectionUpgradePrice, facetsToSgd, formatFacets } from '../src/data/cosmeticStore.js';

mountShell({ page: 'store' });

const tabs = document.getElementById('storeTabs');
const content = document.getElementById('storeContent');
const status = document.getElementById('storeStatus');
const purchaseDialog = document.getElementById('purchaseDialog');
const facetDialog = document.getElementById('facetDialog');
let active = new URLSearchParams(location.search).get('tab') || 'featured';
if (!STORE_SECTIONS.some(([id]) => id === active)) active = 'featured';
let state = { balance: null, owned: [], equipment: {}, resolved: {}, packs: FACET_PACKS, online: false };

const ownedSet = () => new Set((state.owned || []).map(item => typeof item === 'string' ? item : item.id));
const preview = item => `<div class="cosmetic-preview style-${escapeHtml(item.style)}"><div class="cosmetic-preview__window"><div class="cosmetic-preview__bar"><span>${item.style === 'retro-desktop' ? 'gemincremental.exe' : item.typeLabel}</span><span>— □ ×</span></div><div class="cosmetic-preview__gem"><i>${escapeHtml(item.icon)}</i><span>${escapeHtml(item.name)}</span><small>1 in 8,500,000 · Stored</small></div></div></div>`;

function setStatus(message, error = false) { status.textContent = message; status.classList.toggle('error', error); }
function syncWallet() {
  document.getElementById('facetBalance').textContent = state.balance == null ? '— Facets' : formatFacets(state.balance);
  document.getElementById('facetEquivalent').textContent = state.balance == null ? '100 Facets = S$1.00' : `${facetsToSgd(state.balance)} cosmetic value`;
}

function card(item) {
  const owned = ownedSet().has(item.id);
  return `<article class="cosmetic-card card" data-cosmetic-id="${escapeHtml(item.id)}">${preview(item)}<div class="cosmetic-card__body"><div class="cosmetic-card__meta"><span>${escapeHtml(item.typeLabel)}</span>${item.credit ? `<span>Concept: ${escapeHtml(item.credit)}</span>` : `<span>${escapeHtml(item.collectionId || 'Standalone')}</span>`}</div><h3>${escapeHtml(item.name)}</h3><p>${escapeHtml(item.description)}</p><div class="cosmetic-card__footer"><span class="facet-price">${formatFacets(item.price)}<small>${facetsToSgd(item.price)}</small></span>${owned ? `<button class="btn" data-equip="${escapeHtml(item.id)}" data-slot="${escapeHtml(item.type)}">Equip now</button>` : `<button class="btn btn--primary" data-buy="${escapeHtml(item.id)}" data-kind="item" ${state.online ? '' : 'disabled'}>Preview & buy</button>`}</div></div></article>`;
}

function cardsSection(title, copy, items) {
  return `<div class="store-section-head"><div><h2>${escapeHtml(title)}</h2><p>${escapeHtml(copy)}</p></div></div><div class="cosmetic-grid">${items.map(card).join('')}</div>`;
}

function collections() {
  const owned = ownedSet();
  return `<div class="store-section-head"><div><h2>Collections</h2><p>Every collection is 600 Facets instead of 800. Already own a piece? The server removes its full value, then applies the same 25% bundle discount to what remains.</p></div></div><div class="collection-grid">${COSMETIC_COLLECTIONS.map(collection => {
    const pieces = COSMETIC_ITEMS.filter(item => item.collectionId === collection.id);
    const price = collectionUpgradePrice(collection, owned);
    return `<article class="collection-card card"><div class="collection-emblem style-${collection.style}">${collection.icon}</div><div><span class="store-kicker">4-PIECE COLLECTION</span><h3>${collection.name}</h3><p>${collection.description}</p><div class="collection-pieces">${pieces.map(piece => `<span class="${owned.has(piece.id) ? 'is-owned' : ''}">${owned.has(piece.id) ? '✓ ' : ''}${escapeHtml(piece.typeLabel)}</span>`).join('')}</div></div><div class="collection-price">${price ? `<div><strong>${formatFacets(price)}</strong><del>${formatFacets(pieces.filter(piece => !owned.has(piece.id)).reduce((sum,piece) => sum + piece.price, 0))}</del><small>25% off every unowned piece · calculated by the server</small></div><button class="btn btn--primary" data-buy="${collection.id}" data-kind="collection" ${state.online ? '' : 'disabled'}>Complete collection</button>` : `<span class="owned-pill">Collection owned</span>`}</div></article>`;
  }).join('')}</div>`;
}

const option = (item, selected) => `<option value="${escapeHtml(item.id)}" ${selected === item.id ? 'selected' : ''}>${escapeHtml(item.name)}</option>`;
function singleSelect(slot, label, equipment, owned) {
  const items = owned.filter(item => item.slots?.includes(slot) || item.type === slot);
  return `<div class="loadout-group"><label for="loadout-${slot}">${escapeHtml(label)}</label><select id="loadout-${slot}" name="${slot}"><option value="">${slot === 'background' ? 'Default profile' : slot === 'roll_card' || slot === 'leaderboard_skin' ? 'Default theme' : 'None'}</option>${items.map(item => option(item,equipment[slot])).join('')}</select></div>`;
}
function myCosmetics() {
  const owned = state.owned || [];
  const equipment = state.equipment || {};
  const indexed = new Map([...COSMETIC_ITEMS, ...owned].map(item => [item.id,item]));
  const normalized = owned.map(item => ({ ...indexed.get(item.id), ...item, slots: item.slots || [item.type] }));
  const multi = (slot, name, count, selected=[]) => Array.from({length:count},(_,i) => `<div class="loadout-group"><label>${escapeHtml(name)} ${i+1}</label><select name="${slot}-${i}"><option value="">None</option>${normalized.filter(item => slot === 'trophy' || item.slots?.includes(slot)).map(item => option(item,selected[i])).join('')}</select></div>`).join('');
  return `<div class="store-section-head"><div><h2>My Cosmetics</h2><p>Equip purchased themes and everything you have earned through play. Unequipping and defaults are always free.</p></div></div><div class="my-cosmetics"><aside class="loadout-summary card"><span class="store-kicker">OWNED</span><h3>${normalized.length} cosmetics</h3><p>This is the only equipment editor. Your public Profile remains the showcase.</p><a class="btn" href="/user/">View my Profile</a></aside><form class="loadout-form card" id="loadoutForm"><div class="loadout-groups">${singleSelect('title','Collectible title',equipment,normalized)}${singleSelect('background','Profile background',equipment,normalized)}${singleSelect('roll_card','Roll card',equipment,normalized)}${singleSelect('leaderboard_skin','Leaderboard skin',equipment,normalized)}${singleSelect('frame','Avatar frame',equipment,normalized)}${singleSelect('decor','Profile decoration',equipment,normalized)}<fieldset class="loadout-fieldset"><legend>Badges · up to 3</legend><div class="loadout-groups">${multi('badge','Badge',3,equipment.badges)}</div></fieldset><fieldset class="loadout-fieldset"><legend>Trophy case · up to 5</legend><div class="loadout-groups">${multi('trophy','Accomplishment',5,equipment.trophies)}</div></fieldset><fieldset class="loadout-fieldset"><legend>Gem showcase labels</legend><div class="loadout-groups">${[0,1,2].map(i => `<div class="loadout-group"><label>Gem ${i+1}</label><input name="label-${i}" maxlength="32" value="${escapeHtml(equipment.showcase_labels?.[i] || '')}"></div>`).join('')}</div></fieldset></div><p id="loadoutStatus" role="status"></p><div class="loadout-actions"><button class="btn btn--primary" type="submit" ${state.online ? '' : 'disabled'}>Save loadout</button></div></form></div>`;
}

function render() {
  tabs.innerHTML = STORE_SECTIONS.map(([id,label]) => `<button class="store-tab" data-tab="${id}" aria-selected="${id===active}">${escapeHtml(label)}</button>`).join('');
  const filtered = active === 'featured' ? COSMETIC_ITEMS.filter(item => item.featured) : COSMETIC_ITEMS.filter(item => item.type === active);
  if (active === 'collections') content.innerHTML = collections();
  else if (active === 'my-cosmetics') content.innerHTML = myCosmetics();
  else content.innerHTML = cardsSection(STORE_SECTIONS.find(([id]) => id === active)?.[1] || 'Featured', active === 'featured' ? 'A rotating selection of complete visual treatments. Preview every cosmetic before spending Facets.' : 'Every item is cosmetic-only and can be unequipped at any time.', filtered);
  bind();
}

function bind() {
  tabs.querySelectorAll('[data-tab]').forEach(button => button.onclick = () => { active = button.dataset.tab; history.replaceState(null,'',`?tab=${active}`); render(); });
  content.querySelectorAll('[data-buy]').forEach(button => button.onclick = () => openPurchase(button.dataset.kind, button.dataset.buy));
  content.querySelectorAll('[data-equip]').forEach(button => button.onclick = async () => {
    const next = { ...(state.equipment || {}), [button.dataset.slot]: button.dataset.equip };
    try { await saveCosmeticLoadout(next); state.equipment = next; active='my-cosmetics'; render(); setStatus('Cosmetic equipped.'); } catch (error) { setStatus(error.message || 'Could not equip this cosmetic.',true); }
  });
  const form = document.getElementById('loadoutForm');
  if (form) form.onsubmit = saveLoadout;
}

function priceFor(kind,id) {
  if (kind === 'item') return COSMETIC_ITEMS.find(item => item.id === id)?.price || 0;
  const collection = COSMETIC_COLLECTIONS.find(item => item.id === id);
  return collection ? collectionUpgradePrice(collection, ownedSet()) : 0;
}
function nameFor(kind,id) { return kind === 'item' ? COSMETIC_ITEMS.find(item => item.id===id)?.name : `${COSMETIC_COLLECTIONS.find(item=>item.id===id)?.name} Collection`; }
function openPurchase(kind,id) {
  const price = priceFor(kind,id); const before = Number(state.balance || 0); const after = before-price;
  document.getElementById('purchaseDialogTitle').textContent = nameFor(kind,id) || 'Purchase cosmetic';
  document.getElementById('purchaseDialogBody').innerHTML = `<p>The server will re-check ownership, the final price and your balance before granting anything.</p><div class="balance-flow"><div><span>Before</span><strong>${formatFacets(before)}</strong></div><span>→</span><div><span>After</span><strong>${formatFacets(after)}</strong></div></div><p><strong>Price:</strong> ${formatFacets(price)} · ${facetsToSgd(price)}</p>`;
  const confirm = document.getElementById('confirmPurchase'); confirm.disabled = after < 0; confirm.textContent = after < 0 ? 'Not enough Facets' : `Spend ${price} Facets`;
  document.getElementById('purchaseDialogStatus').textContent = '';
  document.getElementById('purchaseForm').onsubmit = async event => {
    if (event.submitter?.value === 'cancel') return;
    event.preventDefault(); confirm.disabled=true; document.getElementById('purchaseDialogStatus').textContent='Completing purchase…';
    try { const result = await purchaseCosmetic({kind,id,requestId:crypto.randomUUID()}); state.balance=result.balance_after; state.owned=result.owned; state.equipment=result.equipment || state.equipment; syncWallet(); purchaseDialog.close(); render(); setStatus(`${nameFor(kind,id)} purchased. You can equip it now.`); }
    catch(error){ document.getElementById('purchaseDialogStatus').textContent=error.message||'Purchase could not be completed.'; confirm.disabled=false; }
  };
  purchaseDialog.showModal();
}

async function saveLoadout(event) {
  event.preventDefault(); const form = new FormData(event.currentTarget);
  const next = Object.fromEntries(['title','background','roll_card','leaderboard_skin','frame','decor'].map(slot => [slot,form.get(slot)||null]));
  next.badges=[0,1,2].map(i=>form.get(`badge-${i}`)).filter(Boolean); next.trophies=[0,1,2,3,4].map(i=>form.get(`trophy-${i}`)).filter(Boolean); next.showcase_labels=[0,1,2].map(i=>String(form.get(`label-${i}`)||'').trim());
  const message=document.getElementById('loadoutStatus'); message.textContent='Saving…';
  try{state.resolved=await saveCosmeticLoadout(next);state.equipment=next;message.textContent='Your cosmetic loadout is saved.';}catch(error){message.textContent=error.message||'Could not save your loadout.';}
}

function renderPacks() {
  const packs = state.packs?.length ? state.packs : FACET_PACKS;
  document.getElementById('facetPacks').innerHTML = packs.map(pack => `<div class="facet-pack"><strong>${formatFacets(pack.facets)}</strong><span>${facetsToSgd(pack.facets)}</span>${pack.checkout_url ? `<a class="btn btn--primary" href="${escapeHtml(pack.checkout_url)}" target="_blank" rel="noopener">Buy pack</a>` : `<button class="btn" disabled>Checkout not configured</button>`}</div>`).join('');
}
document.getElementById('buyFacetsButton').onclick = () => { renderPacks(); facetDialog.showModal(); };
document.getElementById('generateClaimCode').onclick = async () => { const button=document.getElementById('generateClaimCode');button.disabled=true;try{const result=await createFacetClaimCode();document.getElementById('facetClaimCode').textContent=result.code;}catch(error){document.getElementById('facetClaimCode').textContent=error.message||'Could not generate a code.';}finally{button.disabled=false;} };

async function start() {
  render(); syncWallet();
  const user = await ensurePlayerAuth(); if (!user) { setStatus('Sign in to view your Facets and cosmetics.'); return; }
  try { const data=await loadCosmeticStore(); state={...state,...data,online:true}; syncWallet(); render(); setStatus(''); }
  catch(error){ setStatus('Store preview is available, but purchases stay locked until the Facets migration is deployed.',true); }
}
start();
