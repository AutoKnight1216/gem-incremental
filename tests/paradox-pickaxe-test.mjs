import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {
  PICKAXE_STATS, prepareEquipmentRoll, finishEquipmentRoll,
  paradoxConditionCount, advanceParadoxTrial
} from '../supabase/functions/roll/equipmentRules.js';
import {paradoxRecipes} from '../src/data/equipmentOverhaul.js';

assert.deepEqual(PICKAXE_STATS['paradox-pickaxe'],[34,3.1,1.5,5.5,1.7]);
const recipe=paradoxRecipes[0];
assert.equal(recipe.moneyCost,4_000_000_000);
assert.equal(recipe.reward.tier,16);
assert.deepEqual(recipe.reward.bonus,{luck:33,rollSpeed:2.1,mutationChance:.5,weightLuck:4.5,weightMultiplier:.7});

const perfect={rarity:1_000_000,naturalWeight:3,gem:{rarity:1_000_000},naturalMutationCount:1,value:25_000_000,effectiveRarity:1_000_000_000};
assert.equal(paradoxConditionCount(perfect),5);
assert.equal(paradoxConditionCount({...perfect,effectiveRarity:999_999_999}),4);

let context=prepareEquipmentRoll('paradox-pickaxe',{paradox:{contradiction:980,mode:'normal'}},()=>1);
let state=finishEquipmentRoll(context,{...perfect,effectiveRarity:999_999_999}).state;
assert.deepEqual(state.paradox,{contradiction:20,mode:'critical',criticalRoll:1,lastConditions:4});

for(let roll=1;roll<=9;roll++){
 context=prepareEquipmentRoll('paradox-pickaxe',state,()=>1);
 assert.equal(context.flags.paradox.criticalRoll,roll);
 assert.equal(context.flags.paradox.multiplier,1+roll/10);
 assert.equal(context.stats[1],3.1,'Critical never changes Roll Speed');
 state=finishEquipmentRoll(context,perfect).state;
 assert.equal(state.paradox.contradiction,20,'Critical retains overflow and generates no charge');
}
context=prepareEquipmentRoll('paradox-pickaxe',state,()=>1);
assert.equal(context.flags.paradox.criticalRoll,10);
assert.deepEqual(context.stats,[68,3.1,3,11,3.4]);
state=finishEquipmentRoll(context,perfect).state;
assert.equal(state.paradox.mode,'resolved');
context=prepareEquipmentRoll('paradox-pickaxe',state,()=>1);
assert.deepEqual(context.stats,[102,3.1,4.5,16.5,5.1]);
state=finishEquipmentRoll(context,perfect).state;
assert.equal(state.paradox.mode,'normal');
assert.equal(state.paradox.contradiction,20);

// Retained overflow can queue another sequence after Critical/Resolved.
state={paradox:{contradiction:1250,mode:'critical',criticalRoll:10}};
context=prepareEquipmentRoll('paradox-pickaxe',state,()=>1);
state=finishEquipmentRoll(context,{...perfect,naturalMutationCount:0}).state;
assert.deepEqual(state.paradox,{contradiction:250,mode:'critical',criticalRoll:1,lastConditions:4});

const trial={paradoxTrial:{active:true,completed:false,rolls:9995,checkpoints:{legendary:false,mythic:false,exotic:false,exalted:false,cosmic:false}}};
for(const rarity of [1e7,1e7,1e6,1e5,1e4,1e3]) advanceParadoxTrial(trial,rarity);
assert.equal(trial.paradoxTrial.rolls,10000);
assert.deepEqual(trial.paradoxTrial.checkpoints,{legendary:true,mythic:true,exotic:true,exalted:true,cosmic:true});
assert.equal(trial.paradoxTrial.completed,true,'one roll fills only the highest unfinished eligible checkpoint');

const migration=readFileSync(new URL('../supabase/migrations/20261001123656_paradox_pickaxe.sql',import.meta.url),'utf8');
assert.match(migration,/p\.total_rolls>=999999/);
assert.doesNotMatch(migration,/equipment_genuine_rolls/);
assert.match(migration,/paradox_private\.deposit_specimen/);
assert.match(migration,/natural_mutation_ids/);
assert.match(migration,/complete_paradox_trial/);
const edge=readFileSync(new URL('../supabase/functions/roll/index.ts',import.meta.url),'utf8');
const phase6=readFileSync(new URL('../supabase/migrations/20261002053827_phase6_roll_request_amplification.sql',import.meta.url),'utf8');
const rules=readFileSync(new URL('../supabase/functions/roll/equipmentRules.js',import.meta.url),'utf8').trim();
assert.ok(edge.includes(rules),'optimized roll keeps the shared equipment rules synchronized');
assert.match(edge,/naturalMutationCount: naturalMutations\.length/);
assert.match(edge,/roll_route_result/);
assert.match(phase6,/p_active_auto_craft = 'paradox-pickaxe'[\s\S]*paradox_autocraft_deposit/);
assert.match(edge,/complete_paradox_trial/);

console.log('Paradox recipe, overlap/provenance migration, Final Trial, overflow, Critical sequence and Resolved rules passed.');
