-- Rare Rolls must show the same final Luck and immutable serial as the
-- committed inventory specimen. raw_luck is calculated earlier in the roll
-- pipeline and is not authoritative for the specimen card's final Luck.

create or replace function public.capture_best_roll_serial()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_serial_number bigint;
  v_luck_at_roll numeric;
begin
  if new.roll_number is not null then
    select g.serial_number, g.luck_at_roll
    into v_serial_number, v_luck_at_roll
    from public.inventory_gems g
    where g.player_id = new.player_id
      and g.gem_name = new.gem_name
      and (
        g.roll_number = new.roll_number
        or abs(extract(epoch from (g.created_at - new.created_at))) <= 60
      )
    order by
      (g.roll_number = new.roll_number) desc,
      abs(extract(epoch from (g.created_at - new.created_at))) asc,
      g.id asc
    limit 1;

    if found then
      new.serial_number := coalesce(v_serial_number, new.serial_number);
      new.raw_luck := coalesce(v_luck_at_roll, new.raw_luck);
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists capture_best_roll_serial_trg on public.best_roll_history;
create trigger capture_best_roll_serial_trg
before insert on public.best_roll_history
for each row execute function public.capture_best_roll_serial();

-- Repair retained genuine rolls that predate the corrected capture trigger.
with specimen_details as (
  select distinct on (h.id)
    h.id as history_id,
    g.luck_at_roll,
    g.serial_number
  from public.best_roll_history h
  join public.inventory_gems g
    on g.player_id = h.player_id
   and g.gem_name = h.gem_name
   and (
     g.roll_number = h.roll_number
     or abs(extract(epoch from (g.created_at - h.created_at))) <= 60
   )
  where h.roll_number is not null
  order by
    h.id,
    (g.roll_number = h.roll_number) desc,
    abs(extract(epoch from (g.created_at - h.created_at))) asc,
    g.id asc
)
update public.best_roll_history h
set
  raw_luck = coalesce(d.luck_at_roll, h.raw_luck),
  serial_number = coalesce(d.serial_number, h.serial_number)
from specimen_details d
where h.id = d.history_id
  and (
    h.raw_luck is distinct from d.luck_at_roll
    or h.serial_number is distinct from d.serial_number
  );

-- PR 474 made these fields durable on the event. Refresh those stored values
-- after repairing their authoritative history rows.
update public.rare_roll_chat_events e
set
  luck_at_roll = h.raw_luck,
  serial_number = h.serial_number
from public.best_roll_history h
where e.source_type = 'history'
  and e.source_id = h.id
  and (
    e.luck_at_roll is distinct from h.raw_luck
    or e.serial_number is distinct from h.serial_number
  );
