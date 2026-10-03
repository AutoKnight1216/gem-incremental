-- One public, read-only maintenance window. Admin writes go through the
-- authenticated admin Edge Function so clients can never schedule downtime.
create table if not exists public.game_maintenance (
  id text primary key default 'global' check (id = 'global'),
  starts_at timestamptz,
  ends_at timestamptz,
  message text not null default 'The game is shutting down for an update.',
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint game_maintenance_window_complete check (
    (starts_at is null and ends_at is null)
    or (starts_at is not null and ends_at is not null)
  ),
  constraint game_maintenance_minimum_duration check (
    starts_at is null or ends_at >= starts_at + interval '1 minute'
  ),
  constraint game_maintenance_message_length check (
    char_length(btrim(message)) between 1 and 300
  )
);

insert into public.game_maintenance (id)
values ('global')
on conflict (id) do nothing;

alter table public.game_maintenance enable row level security;

revoke all on table public.game_maintenance from anon, authenticated;
grant select on table public.game_maintenance to anon, authenticated;
grant select, insert, update, delete on table public.game_maintenance to service_role;

create policy "Maintenance status is public"
  on public.game_maintenance
  for select
  to anon, authenticated
  using (true);

-- Return the database clock alongside the window so countdowns do not depend
-- on a player's device clock being correct. This remains SECURITY INVOKER and
-- reads only the single row exposed by the SELECT policy above.
create or replace function public.get_game_maintenance_status()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'phase', case
      when starts_at is null or ends_at is null or ends_at <= now() then 'inactive'
      when starts_at > now() then 'scheduled'
      else 'active'
    end,
    'startsAt', starts_at,
    'endsAt', ends_at,
    'message', message,
    'serverNow', now(),
    'updatedAt', updated_at
  )
  from public.game_maintenance
  where id = 'global'
$$;

revoke execute on function public.get_game_maintenance_status() from public;
grant execute on function public.get_game_maintenance_status() to anon, authenticated, service_role;
