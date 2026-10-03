-- Grant sixseven67 the same write-capable admin-panel access as other
-- members of public.admins. Resolve the account by username so no player ID
-- needs to be embedded in the client or guessed from display names.
do $migration$
declare
  target_id uuid;
  match_count integer;
begin
  select count(*) into match_count
  from public.players p
  join auth.users u on u.id = p.id
  where lower(btrim(p.username)) = 'sixseven67';

  if match_count > 1 then
    raise exception 'More than one auth account has username sixseven67';
  end if;

  -- Preview databases may not contain the production account yet.
  if match_count = 1 then
    select p.id into target_id
    from public.players p
    where lower(btrim(p.username)) = 'sixseven67';

    insert into public.admins (user_id, note)
    values (target_id, 'sixseven67 · admin editor')
    on conflict (user_id) do update set note = excluded.note;

    delete from public.admin_viewers where user_id = target_id;
  end if;
end;
$migration$;
