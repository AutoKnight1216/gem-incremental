-- Separate panel viewers from mutation-capable administrators. Legacy
-- SECURITY DEFINER RPCs use public.admins as their authorization boundary, so
-- keeping only the owner there also protects those RPCs from manual calls.
--
-- public.admin_viewers is server-readable only; browser clients cannot inspect
-- or modify the allow-list.
create table if not exists public.admin_viewers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  note text,
  created_at timestamptz not null default now()
);

alter table public.admin_viewers enable row level security;
revoke all on public.admin_viewers from anon, authenticated;

-- Preserve every existing non-owner administrator as a read-only viewer.
insert into public.admin_viewers (user_id, note, created_at)
select user_id, coalesce(note, 'Read-only admin'), created_at
from public.admins
where user_id <> '004d883f-edbc-4610-b5e3-9068a0de0ca2'::uuid
on conflict (user_id) do update set note = excluded.note;

delete from public.admins
where user_id <> '004d883f-edbc-4610-b5e3-9068a0de0ca2'::uuid;

-- Ensure the owner remains the sole write-capable administrator.
insert into public.admins (user_id, note)
select '004d883f-edbc-4610-b5e3-9068a0de0ca2'::uuid, 'Gem Incremental owner'
where exists (
  select 1 from auth.users
  where id = '004d883f-edbc-4610-b5e3-9068a0de0ca2'::uuid
)
on conflict (user_id) do update set note = excluded.note;

-- Add Flame and Kei to the read-only allow-list. Guard each seed on
-- auth.users so fresh preview databases without these accounts still migrate.
insert into public.admin_viewers (user_id, note)
select seed.user_id, seed.note
from (values
  ('bddf7c33-e69c-44e5-98db-3bcc10e582ba'::uuid, 'Flame · read-only admin'),
  ('657b756e-c21e-40ab-b2b5-b13403f89039'::uuid, 'Kei · read-only admin')
) as seed(user_id, note)
where exists (select 1 from auth.users u where u.id = seed.user_id)
on conflict (user_id) do update set note = excluded.note;

-- Several historical functions contain a bootstrap UUID predating the
-- current owner. Rewrite that literal in-place so every legacy admin RPC uses
-- lankystovegaming as its sole hardcoded fallback. This does not change any
-- function's signature, grants, security mode, or implementation otherwise.
do $$
declare
  function_row record;
begin
  for function_row in
    select pg_get_functiondef(p.oid) as definition
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and pg_get_functiondef(p.oid) like '%38d5e8ce-18af-46d3-aa9e-6e601e75dd78%'
  loop
    execute replace(
      function_row.definition,
      '38d5e8ce-18af-46d3-aa9e-6e601e75dd78',
      '004d883f-edbc-4610-b5e3-9068a0de0ca2'
    );
  end loop;
end;
$$;
