-- Emulates the parts of Supabase the schema depends on, so the DDL and the
-- RLS policies can be exercised against vanilla Postgres exactly as written.
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then
    create role service_role nologin bypassrls;
  end if;
end $$;

create schema if not exists auth;

-- Identical semantics to Supabase's auth.uid()
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid
$$;

grant usage on schema auth to authenticated, service_role;

-- Supabase's default privileges (#31). A live project runs these for the
-- migration role, so every object a migration creates in `public` arrives
-- with ALL privileges for all three API roles unless a migration says
-- otherwise. Emulated here so the suite starts from the platform's state,
-- not from a cleaner one: without these lines, "anon holds nothing" would
-- pass whether or not migration 0005 exists. (Applies to objects created by
-- the role running this file, which is the role that runs the migrations.)
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on functions to anon, authenticated, service_role;

-- Roles are cluster-wide, so a cluster reused across runs (or across the
-- superuser and SCHEMA_TEST_AS_MIGRATOR modes) can carry memberships in
-- 0008's roles from an earlier run. 0008 refuses to adopt a portal role with
-- a member other than the migration role or a superuser (security review of
-- #61), so start every run from a fresh project's state: no members at all.
select format('revoke %I from %I granted by %I cascade',
              m.roleid::regrole, m.member::regrole, m.grantor::regrole)
from pg_auth_members m
where m.roleid in (select oid from pg_roles where rolname in ('portal_owner', 'portal_reader'))
\gexec
