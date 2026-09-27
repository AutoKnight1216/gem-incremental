-- Keep display-only Rare Rolls details on the durable event itself. The prior
-- projection joined best_roll_history at read time, so Luck and serials
-- disappeared whenever the source history row was no longer available.

alter table public.rare_roll_chat_events
  add column if not exists luck_at_roll numeric,
  add column if not exists serial_number bigint;

update public.rare_roll_chat_events e
set
  luck_at_roll = coalesce(e.luck_at_roll, h.raw_luck, e.base_luck),
  serial_number = coalesce(e.serial_number, h.serial_number)
from public.best_roll_history h
where e.source_type = 'history'
  and h.id = e.source_id
  and (e.luck_at_roll is null or e.serial_number is null);

-- Rows whose old source history has already gone can still retain the event's
-- recorded base Luck. A deleted history row cannot safely reconstruct a serial.
update public.rare_roll_chat_events
set luck_at_roll = base_luck
where luck_at_roll is null
  and base_luck is not null;

create or replace function public.persist_rare_roll_chat_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_effective_rarity numeric;
  v_has_mutations boolean;
  v_is_anomalous boolean;
begin
  v_has_mutations := cardinality(coalesce(new.mutation_ids, '{}'::text[])) > 0;
  v_effective_rarity := greatest(
    1,
    new.rarity * public.get_mutation_chance_product(coalesce(new.mutation_ids, '{}'::text[]))
  );

  select exists (
    select 1
    from public.private_feature_gems g
    where lower(g.name) = lower(new.gem_name)
      and lower(coalesce(g.metadata->>'rarityClass', '')) = 'anomalous'
  ) into v_is_anomalous;

  if v_is_anomalous
     or new.rarity >= 100000000
     or (
       new.rarity < 100000000
       and v_has_mutations
       and v_effective_rarity >= 10000000000
     ) then
    insert into public.rare_roll_chat_events (
      source_type,
      source_id,
      player_id,
      username,
      gem_name,
      rarity,
      effective_rarity,
      mutation_ids,
      base_luck,
      luck_at_roll,
      serial_number,
      created_at
    ) values (
      'history',
      new.id,
      new.player_id,
      new.username,
      new.gem_name,
      new.rarity,
      v_effective_rarity,
      coalesce(new.mutation_ids, '{}'::text[]),
      new.base_luck,
      new.raw_luck,
      new.serial_number,
      new.created_at
    )
    on conflict (source_type, source_id) where source_id is not null do update
    set
      luck_at_roll = coalesce(public.rare_roll_chat_events.luck_at_roll, excluded.luck_at_roll),
      serial_number = coalesce(public.rare_roll_chat_events.serial_number, excluded.serial_number);
  end if;

  return new;
end;
$function$;

revoke all on function public.persist_rare_roll_chat_event() from public;

-- p_limit is deliberately per category: one busy feed must not push the other
-- category out of the response. The client requests five and receives at most
-- five Base rarity plus five Mutation effective discoveries.
drop function if exists public.get_rare_roll_chat_history(integer);
create or replace function public.get_rare_roll_chat_history(p_limit integer default 5)
returns table(
  id bigint,
  player_id uuid,
  username text,
  title text,
  title_color text,
  gem_name text,
  rarity numeric,
  effective_rarity numeric,
  mutation_ids text[],
  rarity_class text,
  base_luck numeric,
  luck_at_roll numeric,
  serial_number bigint,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $function$
  with eligible as (
    select
      e.*,
      case
        when lower(coalesce(g.metadata->>'rarityClass', '')) = 'anomalous' then 'anomalous'
        else null
      end as rarity_class,
      case
        when lower(coalesce(g.metadata->>'rarityClass', '')) = 'anomalous'
          or e.rarity >= 100000000
          then 'base'
        else 'mutation'
      end as category,
      coalesce(e.luck_at_roll, h.raw_luck, e.base_luck) as recorded_luck,
      coalesce(e.serial_number, h.serial_number) as recorded_serial
    from public.rare_roll_chat_events e
    left join public.private_feature_gems g on lower(g.name) = lower(e.gem_name)
    left join public.best_roll_history h
      on e.source_type = 'history' and h.id = e.source_id
    where lower(coalesce(g.metadata->>'rarityClass', '')) = 'anomalous'
       or e.rarity >= 100000000
       or (
         e.rarity < 100000000
         and cardinality(coalesce(e.mutation_ids, '{}'::text[])) > 0
         and e.effective_rarity >= 10000000000
       )
  ),
  ranked as (
    select
      eligible.*,
      row_number() over (
        partition by category
        order by created_at desc, id desc
      ) as category_rank
    from eligible
  )
  select
    r.id,
    r.player_id,
    r.username,
    coalesce(t.title, '') as title,
    coalesce(t.color, '#ffd166') as title_color,
    r.gem_name,
    r.rarity,
    r.effective_rarity,
    r.mutation_ids,
    r.rarity_class,
    r.base_luck,
    r.recorded_luck as luck_at_roll,
    r.recorded_serial as serial_number,
    r.created_at
  from ranked r
  left join public.player_titles t on t.player_id = r.player_id
  where r.category_rank <= greatest(1, least(coalesce(p_limit, 5), 100))
  order by r.created_at desc, r.id desc;
$function$;

revoke all on function public.get_rare_roll_chat_history(integer) from public;
grant execute on function public.get_rare_roll_chat_history(integer) to anon, authenticated;
