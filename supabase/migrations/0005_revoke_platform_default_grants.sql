-- =============================================================
-- 0005 — revoke the platform's default grants to anon; make every
--        other role's privileges in `public` a stated decision
-- Issue #31. Relates to SDD §4 (RLS), §2.3 (access paths), §13,
-- ADR-0002, ADR-0006. Evidence: #27 (live db diff, harness NOTE lines).
--
-- Expand-only (docs/runbooks/migrations.md): nothing below removes a
-- privilege any deployed or planned code path uses. anon is used by no
-- data path at all (SDD §2.3 — instructors are `authenticated`, the bride
-- portal is the server's service-role client, jobs are in-database).
-- =============================================================
--
-- WHAT THE PLATFORM DOES THAT schema.sql NEVER ASKED FOR
--
-- A Supabase project runs, for the migration role `postgres`:
--
--   alter default privileges in schema public
--     grant all on tables, sequences, functions to anon, authenticated, service_role;
--
-- so every relation 0001 created arrived with ALL privileges for anon and
-- service_role, and with TRUNCATE/REFERENCES/TRIGGER (plus INSERT/UPDATE/
-- DELETE on the views) for authenticated, none of which the explicit grant
-- list in 0001 states. RLS currently reduces anon to zero rows everywhere
-- (verified live, #27), so this is not an active leak. It is a missing
-- layer: the design intends two independent ones in front of bride data —
-- privileges, then RLS — and live the first was absent for anon.
-- docs/schema.bootstrap.sql now emulates those defaults, so the CI suite
-- runs against the same starting point as a real project and fails if this
-- migration is reverted.
--
-- WHAT THIS MIGRATION DECIDES, ROLE BY ROLE
--
-- anon — nothing. No privilege on any table, view, sequence or function in
--   `public`, now or for objects created later. No data path uses anon.
--
-- authenticated — exactly what migrations grant explicitly, no more.
--   Existing objects: TRUNCATE, REFERENCES, TRIGGER are revoked everywhere
--   (TRUNCATE on access_log would let an instructor erase her audit trail
--   without ever touching the absent DELETE policy — RLS does not apply to
--   TRUNCATE), and INSERT/UPDATE/DELETE are revoked on views, which 0001
--   grants SELECT only. Sequences: none (identity columns need no sequence
--   privilege; UPDATE on access_log's sequence would be setval()).
--   Future objects: no default privilege at all. A new table forgotten
--   without RLS is then "permission denied", not cross-tenant disclosure.
--
-- service_role — DELIBERATELY UNCHANGED, and now stated rather than implied.
--   It holds BYPASSRLS, so table privileges are its only database-side
--   limit; revoking them would be the right instinct in the abstract. It is
--   kept because:
--     * the bride portal read path (lib/data/portal.ts, invariant 5) reads
--       portal_session_view, and later portal relations, as service_role;
--     * the staging RLS harness (scripts/test-live-rls.mjs) seeds and
--       cleans fixtures through it;
--     * invariant 5 bounds its blast radius by confining the KEY to one
--       module (a lint rule) and the environment (docs/runbooks/
--       provisioning.md), not by grants — a holder of that key can mint an
--       instructor JWT and become `authenticated` anyway.
--   Its table grants are re-stated explicitly below (a no-op on a live
--   project) so the schema the migrations describe and the schema the
--   platform holds are the same, and `supabase db diff` stops reporting
--   them. Function EXECUTE is NOT re-stated: functions grant service_role
--   individually (0002 revokes it from bootstrap_instructor on purpose).
--   One narrowing is made elsewhere, by name: 0006 revokes service_role's
--   SELECT on session_record's three private columns.
--
-- PUBLIC — EXECUTE on functions is a Postgres default (not Supabase's), and
--   anon inherits through it. Revoked from every existing function this
--   role owns, and from the global default for functions it creates later.
--
-- THE RULE FOR EVERY LATER MIGRATION (0006 onward, and lanes A/C)
--
--   1. Objects are closed by default. Grant explicitly to `authenticated`
--      and/or `service_role` exactly what the access path needs, next to
--      the CREATE. Never grant to anon or PUBLIC.
--   2. A function that authenticated may call needs
--      `grant execute ... to authenticated`; one service_role must NOT call
--      needs `revoke execute ... from service_role` (the platform default
--      still grants it).
--   3. schema.test.sql's "#31" section enumerates every relation, sequence
--      and function in `public`, so an object that breaks rule 1 fails CI
--      whichever migration introduced it.
--
-- PLATFORM-OWNED OBJECTS ARE LEFT ALONE
--
--   Every loop below touches only objects owned by the migration role and
--   not belonging to an extension. Objects the platform injects into
--   `public` under its own role (today: public.rls_auto_enable(), owned by
--   supabase_admin) are neither ours to revoke on nor visible to CI; they
--   are the documented allowlist in scripts/verify-live-schema.sh. The
--   platform's default privileges for its own role (supabase_admin) cannot
--   be altered by `postgres` and are not.
-- =============================================================

do $$
declare
  obj record;
begin
  -- Tables, views, materialised views, foreign and partitioned tables.
  for obj in
    select c.oid::regclass as rel, c.relkind
    from pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and c.relowner = current_user::regrole
      and not exists (select 1 from pg_depend d
                      where d.classid = 'pg_class'::regclass and d.objid = c.oid
                        and d.deptype = 'e')
  loop
    execute format('revoke all on %s from anon', obj.rel);
    execute format('revoke truncate, references, trigger on %s from authenticated', obj.rel);
    if obj.relkind in ('v', 'm') then
      execute format('revoke insert, update, delete on %s from authenticated', obj.rel);
    end if;
    execute format('grant select, insert, update, delete, truncate, references, trigger on %s to service_role', obj.rel);
  end loop;

  -- Sequences: nobody outside service_role needs one (identity columns
  -- draw their values without a sequence privilege).
  for obj in
    select c.oid::regclass as rel
    from pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.relkind = 'S'
      and c.relowner = current_user::regrole
      and not exists (select 1 from pg_depend d
                      where d.classid = 'pg_class'::regclass and d.objid = c.oid
                        and d.deptype = 'e')
  loop
    execute format('revoke all on sequence %s from anon, authenticated', obj.rel);
    execute format('grant usage, select, update on sequence %s to service_role', obj.rel);
  end loop;

  -- Functions and procedures: anon and PUBLIC lose EXECUTE. Grants to
  -- authenticated / service_role are each function's own decision and are
  -- left exactly as the migration that created it set them.
  for obj in
    select p.oid::regprocedure as fn, p.prokind
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proowner = current_user::regrole
      and p.prokind in ('f', 'p')
      and not exists (select 1 from pg_depend d
                      where d.classid = 'pg_proc'::regclass and d.objid = p.oid
                        and d.deptype = 'e')
  loop
    execute format('revoke execute on %s %s from public, anon',
                   case obj.prokind when 'p' then 'procedure' else 'function' end,
                   obj.fn);
  end loop;
end $$;

-- ---------- future objects created by this role ----------
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
-- PUBLIC's EXECUTE is a global default; a per-schema REVOKE cannot remove
-- it (Postgres docs, ALTER DEFAULT PRIVILEGES), hence no IN SCHEMA here.
alter default privileges revoke execute on functions from public;
-- service_role's default grants in `public` are intentionally left in place
-- (see header). schema.test.sql asserts they are still there, so a later
-- "tidy-up" that removes them is a visible decision, not an accident.
