-- Misty's temporary mutation-chance effect is intentionally limited to three
-- active stacks. This touches only current ephemeral player buff state; it
-- does not rewrite or delete any historical gem or mutation discovery rows.
update public.players
set misty_mutation_boost_stacks = least(3, greatest(0, misty_mutation_boost_stacks))
where misty_mutation_boost_stacks < 0
   or misty_mutation_boost_stacks > 3;

alter table public.players
  drop constraint if exists players_misty_mutation_boost_stacks_max_three;

alter table public.players
  add constraint players_misty_mutation_boost_stacks_max_three
  check (misty_mutation_boost_stacks <= 3);

comment on constraint players_misty_mutation_boost_stacks_max_three on public.players is
  'Misty can have at most three active mutation-chance stacks.';
