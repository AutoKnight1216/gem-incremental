-- Add the two read-only administrators requested for the admin panel.
-- Mutation authority remains application-enforced and belongs only to
-- 004d883f-edbc-4610-b5e3-9068a0de0ca2 (lankystovegaming).
--
-- Guard each seed on auth.users so local/preview databases without these
-- accounts continue to migrate cleanly.
insert into public.admins (user_id, note)
select seed.user_id, seed.note
from (values
  ('bddf7c33-e69c-44e5-98db-3bcc10e582ba'::uuid, 'Flame · read-only admin'),
  ('657b756e-c21e-40ab-b2b5-b13403f89039'::uuid, 'Kei · read-only admin')
) as seed(user_id, note)
where exists (select 1 from auth.users u where u.id = seed.user_id)
on conflict (user_id) do update set note = excluded.note;
