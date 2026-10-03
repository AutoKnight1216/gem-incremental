import assert from "node:assert/strict";
import fs from "node:fs";
import { PGlite } from "@electric-sql/pglite";

const db = new PGlite();
const migration = fs.readFileSync(
  new URL("../supabase/migrations/20261003070256_readonly_admin_economy_access.sql", import.meta.url),
  "utf8"
);

await db.exec(`
  create schema auth;
  create table public.admins(user_id uuid primary key);
  create table public.admin_viewers(user_id uuid primary key);
  create function auth.uid() returns uuid language sql stable as
    $$ select '657b756e-c21e-40ab-b2b5-b13403f89039'::uuid $$;

  create function public.admin_get_economy_breakdown(p_period text default '24H') returns jsonb
  language plpgsql security definer set search_path to '' as $$
  begin
    if auth.uid() is null or not (auth.uid()='004d883f-edbc-4610-b5e3-9068a0de0ca2'::uuid
      or exists(select 1 from public.admins where user_id=auth.uid())) then
      raise exception 'not_admin';
    end if;
    return jsonb_build_object('period', p_period);
  end $$;

  create function public.admin_get_lottery_analytics(p_period text default '24H') returns jsonb
  language plpgsql security definer set search_path to '' as $$
  begin
    if auth.uid() is null or not (auth.uid()='004d883f-edbc-4610-b5e3-9068a0de0ca2'::uuid
      or exists(select 1 from public.admins where user_id=auth.uid())) then
      raise exception 'not_admin';
    end if;
    return jsonb_build_object('period', p_period);
  end $$;

  create function public.get_admin_analytics() returns jsonb
  language plpgsql security definer set search_path to 'public' as $$
  declare v_uid uuid := auth.uid(); v_is_admin boolean := false;
  begin
    select exists(select 1 from public.admins where user_id=v_uid)
      or v_uid='004d883f-edbc-4610-b5e3-9068a0de0ca2'::uuid into v_is_admin;
    if not v_is_admin then raise exception 'not_authorized'; end if;
    return '{}'::jsonb;
  end $$;

  create function public.admin_get_bank_overview() returns jsonb
  language plpgsql security definer set search_path to 'public' as $$
  declare v_is_admin boolean;
  begin
    v_is_admin := auth.uid() is not null and (
      auth.uid() = '004d883f-edbc-4610-b5e3-9068a0de0ca2'::uuid
      or exists (select 1 from public.admins where user_id = auth.uid()));
    if not v_is_admin then raise exception 'not_admin'; end if;
    return '{}'::jsonb;
  end $$;

  insert into public.admin_viewers(user_id)
  values ('657b756e-c21e-40ab-b2b5-b13403f89039');
`);

await db.exec(migration);

for (const query of [
  "select public.admin_get_economy_breakdown('24H')",
  "select public.admin_get_lottery_analytics('24H')",
  "select public.get_admin_analytics()",
  "select public.admin_get_bank_overview()"
]) {
  await assert.doesNotReject(() => db.query(query));
}

const definitions = await db.query(`
  select pg_get_functiondef(p.oid) as definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in (
    'admin_get_economy_breakdown','admin_get_lottery_analytics',
    'get_admin_analytics','admin_get_bank_overview'
  )
`);
for (const row of definitions.rows) {
  assert.match(row.definition, /public\.admin_viewers/);
}

console.log("admin-readonly-economy-database-test passed");
