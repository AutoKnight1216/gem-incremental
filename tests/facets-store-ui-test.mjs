import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { COSMETIC_COLLECTIONS, COSMETIC_ITEMS, FACET_PACKS, collectionUpgradePrice } from '../src/data/cosmeticStore.js';

const read = path => readFileSync(new URL(path, import.meta.url),'utf8');
assert.deepEqual(FACET_PACKS.map(pack=>[pack.facets,pack.cents]),[[100,100],[250,250],[500,500],[1000,1000],[2500,2500]]);
assert.equal(COSMETIC_ITEMS.length,15);
for(const id of ['glitched','celestial','overgrown']){
  const collection=COSMETIC_COLLECTIONS.find(item=>item.id===id);
  const pieces=COSMETIC_ITEMS.filter(item=>item.collectionId===id);
  assert.deepEqual(pieces.map(item=>item.price),[100,250,250,200]);
  assert.equal(collectionUpgradePrice(collection,new Set()),600);
  assert.equal(collectionUpgradePrice(collection,new Set([`${id}-title`])),525);
  assert.equal(collectionUpgradePrice(collection,new Set([`${id}-background`])),413);
  assert.equal(collectionUpgradePrice(collection,new Set(pieces.map(item=>item.id))),0);
}
assert.equal(COSMETIC_ITEMS.find(item=>item.id==='retro-desktop-roll-card').price,250);
const shell=read('../src/ui/shell.js');
assert.match(shell,/id: "store"[\s\S]*href: "store\//);assert.match(shell,/id: "store"[\s\S]*direct: true/);
const profile=read('../user/profile.js');assert.match(profile,/Customize in Store/);assert.doesNotMatch(profile,/openCustomizer/);
const rollCss=read('../style.css');
for(const style of ['glitched','celestial','overgrown','retro-desktop']) assert.ok(rollCss.includes(`data-roll-card="${style}"`));
const profileCss=read('../user/profile.css');
for(const decorativeLabel of ['SIGNAL // FRACTURED','CELESTIAL // STARFORGED','OVERGROWN // RECLAIMED','GLITCHED // SIGNAL LOST','CELESTIAL // CONSTELLATION','OVERGROWN // MINE RECLAIMED','GLITCHED // USER','CELESTIAL // ASCENDANT','OVERGROWN // DEEP ROOT']) {
  assert.ok(!`${rollCss}\n${profileCss}`.includes(decorativeLabel));
}
const leaderboardCss=read('../leaderboards/leaderboards.css');
for(const style of ['glitched','celestial','overgrown']) assert.ok(leaderboardCss.includes(`.leaderboard-row[data-leaderboard-skin="${style}"]`));
for(const decorativeLabel of ['GLITCHED // USER','CELESTIAL // ASCENDANT','OVERGROWN // DEEP ROOT']) assert.ok(!leaderboardCss.includes(decorativeLabel));
assert.doesNotMatch(leaderboardCss,/\.leaderboard-card(?:\[[^\]]*\]|:is\([^)]*\))[^\n{]*data-leaderboard-skin/);
const leaderboardJs=read('../leaderboards/leaderboards.js');
assert.match(leaderboardJs,/get_public_player_titles/);
assert.match(leaderboardJs,/row\.dataset\.leaderboardSkin = skinStyle/);
assert.doesNotMatch(leaderboardJs,/mountEquippedLeaderboardSkin/);
const webhook=read('../supabase/functions/bmc-facets-webhook/index.ts');assert.match(webhook,/x-signature-sha256/);assert.match(webhook,/constantTimeEqual/);assert.match(webhook,/process_bmc_facet_event/);
console.log('Facet catalogue, upgrade math, navigation, previews and webhook verification wiring passed.');
