-- Rebalance the Money Up Potion line. The live sell path reads the active
-- boost's effect_value, so updating the catalog also updates future boosts
-- without changing the optimized roll or auto-sell implementations.

begin;

update public.game_consumables
set effect_value = case id
  when 'money-up-potion' then 1.1
  when 'money-up-potion-2' then 1.25
end
where id in ('money-up-potion', 'money-up-potion-2');

-- Active boosts normally expire after 60 seconds, but rebalance them too so
-- the change is consistent immediately when this migration is applied.
update public.player_boosts
set effect_value = case tier
  when 1 then 1.1
  when 2 then 1.25
  else effect_value
end
where family = 'gemValue' and tier in (1, 2);

insert into public.game_recipes(id, recipe) values
  ('money-up-potion', '{
    "id":"money-up-potion",
    "name":"Money Up Potion",
    "category":"potion",
    "requirements":[
      {"type":"consumable","consumableId":"lucky-potion-1","amount":5},
      {"type":"consumable","consumableId":"fortune-potion-1","amount":5}
    ],
    "moneyCost":25000,
    "reward":{"type":"consumable","id":"money-up-potion","name":"Money Up Potion","family":"gemValue","tier":1,"amount":1,"effectValue":1.1}
  }'::jsonb),
  ('money-up-potion-2', '{
    "id":"money-up-potion-2",
    "name":"Money Up Potion II",
    "category":"potion",
    "requirements":[
      {"type":"consumable","consumableId":"lucky-potion-2","amount":5},
      {"type":"consumable","consumableId":"fortune-potion-2","amount":5},
      {"type":"consumable","consumableId":"money-up-potion","amount":3}
    ],
    "moneyCost":100000,
    "reward":{"type":"consumable","id":"money-up-potion-2","name":"Money Up Potion II","family":"gemValue","tier":2,"amount":1,"effectValue":1.25}
  }'::jsonb)
on conflict (id) do update set recipe = excluded.recipe;

commit;
