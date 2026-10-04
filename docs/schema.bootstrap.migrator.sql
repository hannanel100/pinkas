-- Opt-in second stage of the bootstrap: run the migrations as a NON-superuser
-- migration role, the way a hosted Supabase project does (PR #51 review).
--
-- Run as superuser, after schema.bootstrap.sql and before the migrations
-- (scripts/test-schema.sh does this when SCHEMA_TEST_AS_MIGRATOR=1). It ends
-- with SET ROLE, so every migration that follows in the same psql session
-- is privilege-checked as pinkas_migrator; the harness RESETs the role before
-- schema.test.sql.
--
-- What it emulates about Supabase's `postgres` role, and why each matters:
--   * NOSUPERUSER, CREATEROLE, BYPASSRLS — superuser hides every ownership,
--     membership and schema-privilege check a migration can trip over.
--   * owns the database; `public` is owned by pg_database_owner (the PG15+
--     default, stated anyway) — so it has CREATE on `public` through that,
--     not through superuser.
--   * member of anon/authenticated/service_role WITH ADMIN OPTION. This is an
--     ASSUMPTION about the live platform; migration 0006 needs it (to grant
--     `authenticated` to session_record_reader) and documents the live
--     pre-check that confirms it. Set SCHEMA_TEST_MIGRATOR_ADMIN=0 to emulate
--     a platform where it does not hold — 0006 must then fail, atomically.
--   * the platform's default privileges, for this role.

\if :{?migrator_admin}
\else
\set migrator_admin 1
\endif

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'pinkas_migrator') then
    create role pinkas_migrator nologin nosuperuser createrole bypassrls;
  end if;
end $$;

-- Roles are cluster-wide: a re-run must not inherit a previous run's
-- memberships (in particular its admin option).
select format('revoke %I from pinkas_migrator cascade', m.roleid::regrole)
from pg_auth_members m
where m.member = 'pinkas_migrator'::regrole
  and m.roleid in ('anon'::regrole, 'authenticated'::regrole, 'service_role'::regrole)
\gexec
\if :migrator_admin
grant anon, authenticated, service_role to pinkas_migrator with admin option;
\else
grant anon, authenticated, service_role to pinkas_migrator;
\endif

grant usage on schema auth to pinkas_migrator;

-- On a fresh project 0006 creates session_record_reader and so holds ADMIN
-- on it. On a cluster an earlier run already created it on, hand the
-- migrator the same standing, so this emulates the fresh project rather
-- than failing on leftovers.
select 'grant session_record_reader to pinkas_migrator with admin option'
where exists (select 1 from pg_roles where rolname = 'session_record_reader')
\gexec
-- Likewise for 0008's two roles (#53).
select format('grant %I to pinkas_migrator with admin option', rolname)
from pg_roles where rolname in ('portal_owner', 'portal_reader')
\gexec
select format('alter database %I owner to pinkas_migrator', current_database()) \gexec
alter schema public owner to pg_database_owner;

alter default privileges for role pinkas_migrator in schema public
  grant all on tables    to anon, authenticated, service_role;
alter default privileges for role pinkas_migrator in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges for role pinkas_migrator in schema public
  grant all on functions to anon, authenticated, service_role;

set role pinkas_migrator;
