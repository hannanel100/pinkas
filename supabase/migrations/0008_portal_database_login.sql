-- =============================================================
-- 0008 — containment: the portal gets its own database login, and
--        service_role loses every privilege in `public`
-- Issue #53. Decision: ADR-0010 (settled in the #53 design challenge).
-- Relates to SDD §2.3, §6.2, §13, §16.2; ADR-0002, ADR-0003, ADR-0005,
-- ADR-0006, ADR-0009. Invariants in play: 1, 2, 3, 5.
--
-- NOT expand-only, deliberately (docs/runbooks/migrations.md). It removes
-- every privilege service_role holds in `public` — including the portal
-- grants 0007 made — and every direct grant on the two portal views,
-- including authenticated's SELECT on portal_session_view (0001). That is
-- safe to apply because no deployed code path uses any of them: the portal
-- module (lib/data/portal.ts, #7) is not live and, per ADR-0010, will never
-- hold the service key; no instructor code path reads portal_session_view
-- (instructors read `session` under RLS); jobs run in-database as the
-- migration role. The staging harness (scripts/test-live-rls.mjs), the one
-- consumer of service_role's table grants, is rewritten in the same change.
-- =============================================================
--
-- WHY (short form; the long form is ADR-0010)
--
-- On a live Supabase project service_role holds BYPASSRLS and, through the
-- platform's default privileges, ALL on every relation in `public`. 0005
-- kept that on purpose because the portal read path was going to be the
-- service-role client. ADR-0010 reverses that: the service-role key is also
-- the GoTrue admin credential, so it can never be a contained portal
-- credential. The portal instead connects over the Postgres wire protocol
-- (Supavisor, transaction mode) as a dedicated login that can call three
-- functions and nothing else; the service-role key leaves every deployed
-- environment; and service_role keeps nothing in `public`, so a key that
-- does leak from an operator's keychain cannot dump the database in one
-- query (it can still impersonate an instructor through GoTrue — the
-- residual ADR-0010 records and 0009 addresses).
--
-- THE SHAPE
--
-- 1. portal_reader — the role behind PORTAL_DATABASE_URL.
--      * Created NOLOGIN here. LOGIN and its password are set OUT OF BAND
--        by the operator (infra, #56), so no credential is ever in git:
--          alter role portal_reader with login password '<generated>';
--      * NOBYPASSRLS, NOINHERIT, not a superuser, member of nothing, and
--        nobody but the migration role (or a superuser) is a member of it.
--      * connection limit 20; statement_timeout 2s (role-level, so it
--        applies to every Supavisor backend opened for it). The timeout is
--        a DEFAULT, not a control: any role may `set statement_timeout` in
--        its own session, portal_reader included. It protects against a
--        slow query in portal.ts, not against a hostile holder of the
--        credential.
--      * Privileges: USAGE on schema public and EXECUTE on exactly three
--        functions. No table, view, sequence or column privilege anywhere.
--      * It still holds TEMP on the database, through PUBLIC (a Postgres
--        default). That cannot be revoked from one role without revoking it
--        from PUBLIC — a database-wide change to a platform default that
--        this migration does not make. It is therefore neutralised where it
--        mattered instead: see SEARCH PATH under 3. (Under Supavisor's
--        transaction pooling a temp object can outlive the client that made
--        it and sit in a backend the next portal request reuses; that is
--        harmless only because no function here resolves a name through
--        pg_temp.)
--
-- 2. portal_owner — owns the three functions (the 0006 pattern).
--      * NOLOGIN, NOBYPASSRLS, not a superuser, member of nothing, owner of
--        no table, and nobody but the migration role (which hands the
--        functions over to it) or a superuser is a member of it: a member
--        of portal_owner reaches every live bride's portal columns through
--        the `to portal_owner` policies below. A pre-existing portal_owner
--        or portal_reader with any other member is refused, not adopted
--        (security review of #61). RLS therefore applies to it like to any other role, and
--        it reaches rows only through the policies below, written
--        `to portal_owner` so they mean nothing for anyone else.
--      * Column grants: exactly what the two portal views read, plus the
--        rate-limit counter, plus INSERT on access_log.
--
-- 3. The functions. SECURITY DEFINER, `set search_path = pg_catalog, pg_temp`,
--    every relation, type and function name schema-qualified.
--
--    SEARCH PATH (security review of #61, CRITICAL, fixed here before merge).
--    The first draft used `search_path = ''`. Postgres then STILL searches
--    pg_temp for relation and type names — first. portal_reader can create
--    temp objects (TEMP via PUBLIC, above), so a temp domain named `text` or
--    `timestamptz` whose CHECK called temp code made that code run as
--    portal_owner on any call, with no valid hash: it read every tenant's
--    live brides and wrote forged log rows. Naming pg_temp LAST puts it
--    after pg_catalog, so a built-in type or relation name can never be
--    shadowed; pg_temp is never searched for functions or operators at all.
--    Qualifying every type (`pg_catalog.text`, `pg_catalog.timestamptz`, …)
--    and relation (`public.…`) is the second layer. schema.test.sql's #53
--    section plants temp domains and tables over every name these functions
--    use and calls all three.
--
--    portal_resolve_token(p_token_hash bytea, p_request_id uuid)
--      -> table (bride_id uuid, tenant_id uuid, first_name text,
--                portal_expires_at timestamptz)        -- 0 or 1 row
--    portal_sessions(p_token_hash bytea, p_request_id uuid)
--      -> setof portal_session_view                      -- the 7 columns
--
--      * The hash is the ONLY row selector. `portal_token_hash = $1` is
--        written here, once; the caller cannot widen it, and there is no
--        bride_id parameter to enumerate by. A NULL hash, a hash that is
--        not exactly 32 bytes (sha256), or a NULL request id is refused
--        with 22023 — a call that cannot be a real lookup is a bug.
--      * Expiry, revocation and soft delete are enforced by
--        portal_bride_view (0007), unchanged. A wrong, expired, revoked or
--        deleted link all return zero rows, indistinguishably.
--      * VOLATILE, and each writes its own access_log row in the SAME
--        statement as the read (a data-modifying CTE, the 0006 technique):
--        ('bride_portal', actor_id = bride_id, bride_id, action 'read',
--        resource = the function name, request_id = p_request_id). Keyed on
--        the resolved bride, so a failed lookup writes nothing, and a
--        resolved one writes exactly one row whether or not she has
--        sessions. The actor is a constant here, never a parameter. The
--        portal route therefore does NOT call logAccess (ADR-0010 §2).
--      * The log is complete for any caller that COMMITS — not "by
--        construction" for every caller. Over the wire protocol the caller
--        owns the transaction: `begin; select … portal_sessions(…); rollback;`
--        returns the rows and discards the log row (security review of #61).
--        That needs both PORTAL_DATABASE_URL and a valid token hash. The rule
--        for lib/data/portal.ts: call each function as a plain autocommit
--        SELECT; never wrap a portal call in a transaction, and never one
--        that is rolled back.
--
--    portal_rate_limit_hit(bytea, bytea, integer)
--      * Interface unchanged from 0007. Becomes SECURITY DEFINER owned by
--        portal_owner, with qualified names and the same search_path as
--        above, so the caller needs no privilege on the table. (0007's
--        `public, pg_temp` was harmless for an invoker-rights function, whose
--        temp code would run as the caller anyway; under definer rights it
--        is exactly what must not be inherited.)
--    portal_rate_limit_prune()
--      * Unchanged and executable by nobody but its owner: the pg_cron job
--        runs as the migration role (`postgres` on Supabase), which owns
--        it. Scheduling it remains a go-live precondition for #7 (0007).
--
-- 4. Policies `to portal_owner`, SELECT/INSERT only:
--      * bride:   rows with a token and not soft-deleted — the superset of
--                 what portal_bride_view shows (the view adds expiry).
--      * course, session: rows not soft-deleted — what portal_session_view
--                 shows. These are not tenant-scoped, on purpose: the only
--                 row filter on the portal path is the token hash, applied
--                 inside the functions, and portal_owner cannot be reached
--                 except through them (NOLOGIN, no member but the migration
--                 role).
--      * portal_rate_limit: all rows (not tenant data; 0007).
--      * access_log: INSERT only, and only a row that is
--                 ('bride_portal', actor_id = bride_id) for a bride whose
--                 tenant it names. No SELECT/UPDATE/DELETE policy and no such
--                 privilege: portal_owner can append to the log, never read
--                 or rewrite it. access_log keeps no FK to bride (0001).
--
-- 5. service_role: nothing in `public`. Every table, view and sequence
--    privilege and every function EXECUTE on objects this role owns is
--    revoked (0007's included), and the platform's default privileges for
--    this role are revoked, so a table created by a later migration does not
--    re-grant it. USAGE on the schema is left alone — it grants no data, and
--    the platform manages schema-level grants for its roles.
--    Objects the platform itself creates in `public` under its own role
--    (public.rls_auto_enable(), owned by supabase_admin — see 0005 and
--    verify-live-schema.sh) carry the platform's own defaults; they are not
--    ours to revoke on, and verify-live-schema.sh step 4 reports them.
--
-- 6. The two portal views lose every direct grant (anon, authenticated,
--    service_role, PUBLIC). portal_owner holds SELECT on them; the
--    functions are their only reader. Their column lists, and
--    security_invoker = on, are unchanged.
--
-- APPLYING THIS ON A LIVE PROJECT
--
-- One explicit transaction: a half-applied privilege migration is a state
-- nobody reviewed — and the dangerous half here would be a definer function
-- still owned by the migration role, which holds BYPASSRLS.
--
-- Pre-checks, as the migration role, BEFORE `supabase db push` (each must
-- return what is stated, or stop and take it back to `database`):
--
--   -- 1. Neither role exists yet (roles are cluster-wide). Expect 0 rows.
--   --    If one exists, the migration will refuse it unless it is
--   --    NOBYPASSRLS/NOSUPERUSER (portal_owner also NOLOGIN), member of
--   --    nothing, has no member but the migration role or a superuser, and
--   --    the migration role holds ADMIN on it. To see who is a member:
--   --      select roleid::regrole, member::regrole from pg_auth_members
--   --       where roleid in (select oid from pg_roles
--   --                        where rolname in ('portal_owner','portal_reader'));
--   select rolname from pg_roles where rolname in ('portal_owner', 'portal_reader');
--
--   -- 2. The migration role can create roles. Expect `t`.
--   select rolcreaterole from pg_roles where rolname = current_user;
--
--   -- 3. The migration role can grant CREATE on `public` (needed for the
--   --    ownership hand-over, as in 0006). Expect `t`.
--   select has_schema_privilege(current_user, 'public', 'CREATE WITH GRANT OPTION');
--
-- No ADMIN on `authenticated` is needed: neither new role is granted
-- membership in anything. The migration role is granted membership in
-- portal_owner (to hand the functions over with ALTER ... OWNER TO), which
-- grants it nothing it did not already hold.
--
-- After the push, before anything else (#56):
--   * set LOGIN and the password on portal_reader (out of band, above);
--   * verify a real login and a real function call as portal_reader through
--     Supavisor — the merge gate in ADR-0010 §6;
--   * run scripts/verify-live-schema.sh (step 4 asserts this containment
--     on the live project) and the staging harness.
-- =============================================================

begin;

-- ---------- the two roles ----------
do $$
declare
  r   pg_roles%rowtype;
  nm  text;
begin
  foreach nm in array array['portal_owner', 'portal_reader'] loop
    select * into r from pg_roles where rolname = nm;
    if not found then
      -- NOBYPASSRLS / NOLOGIN are defaults; stated so the intent is greppable.
      execute format('create role %I nologin nobypassrls noinherit', nm);
    elsif r.rolsuper or r.rolbypassrls or r.rolcreaterole or r.rolcreatedb or r.rolreplication
          or (nm = 'portal_owner' and r.rolcanlogin) then
      raise exception
        '% exists with superuser=%, bypassrls=%, createrole=%, createdb=%, replication=%, login=% — refusing to adopt it',
        nm, r.rolsuper, r.rolbypassrls, r.rolcreaterole, r.rolcreatedb, r.rolreplication, r.rolcanlogin;
    elsif exists (select 1 from pg_auth_members m where m.member = r.oid) then
      raise exception '% exists and is a member of another role — refusing to adopt it', nm;
    elsif exists (select 1 from pg_auth_members m
                  join pg_roles g on g.oid = m.member
                  where m.roleid = r.oid
                    and g.rolname <> current_user
                    and not g.rolsuper) then
      -- A member of portal_owner reads every live bride's portal columns
      -- through the `to portal_owner` policies; a member of portal_reader
      -- calls the portal functions. Only the migration role (which hands the
      -- functions over) and superusers (who need no membership) may be one.
      raise exception '% exists and has members (%) — refusing to adopt it',
        nm, (select string_agg(m.member::regrole::text, ', ')
             from pg_auth_members m where m.roleid = r.oid);
    end if;
  end loop;
end $$;

comment on role portal_owner is
  'Owner of the portal_* functions (issue #53, ADR-0010). NOLOGIN, NOBYPASSRLS, '
  'member of nothing; reaches rows only through policies written to portal_owner. '
  'Never make it the owner of a table, and never grant it BYPASSRLS or LOGIN.';
comment on role portal_reader is
  'The bride portal''s database login, PORTAL_DATABASE_URL (issue #53, ADR-0010). '
  'Holds EXECUTE on portal_resolve_token, portal_sessions and portal_rate_limit_hit '
  'and nothing else. LOGIN and password are set out of band, never in a migration.';

alter role portal_reader noinherit connection limit 20;
alter role portal_reader set statement_timeout = '2s';

-- The migration role must be able to SET ROLE to portal_owner to hand the
-- functions over on a platform where it is not a superuser (0006).
grant portal_owner to current_user;

grant usage on schema public to portal_owner, portal_reader;

-- ---------- service_role: nothing in `public` ----------
do $$
declare obj record;
begin
  for obj in
    select c.oid::regclass as rel, c.relkind
    from pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.relkind in ('r', 'p', 'v', 'm', 'f', 'S')
      and c.relowner = current_user::regrole
      and not exists (select 1 from pg_depend d
                      where d.classid = 'pg_class'::regclass and d.objid = c.oid
                        and d.deptype = 'e')
  loop
    -- REVOKE at table level also strips the column-level grants 0006/0007
    -- made (session_record's five columns, bride's six).
    if obj.relkind = 'S' then
      execute format('revoke all on sequence %s from service_role', obj.rel);
    else
      execute format('revoke all on %s from service_role', obj.rel);
    end if;
  end loop;

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
    execute format('revoke execute on %s %s from service_role',
                   case obj.prokind when 'p' then 'procedure' else 'function' end,
                   obj.fn);
  end loop;
end $$;

-- Future objects this role creates: no default grant to service_role.
alter default privileges in schema public revoke all on tables    from service_role;
alter default privileges in schema public revoke all on sequences from service_role;
alter default privileges in schema public revoke all on functions from service_role;

-- ---------- the portal views: no direct reader but portal_owner ----------
revoke all on public.portal_bride_view   from public, anon, authenticated, service_role;
revoke all on public.portal_session_view from public, anon, authenticated, service_role;
grant select on public.portal_bride_view, public.portal_session_view to portal_owner;

-- security_invoker views check the invoker (here portal_owner) column by
-- column on the base tables: these are exactly the columns the two views
-- reference, and the complete list.
grant select (id, tenant_id, first_name, portal_token_hash, portal_expires_at, deleted_at)
  on public.bride to portal_owner;
grant select (id, course_id, order_index, scheduled_at, duration_minutes, location, status, deleted_at)
  on public.session to portal_owner;
grant select (id, bride_id, deleted_at)
  on public.course to portal_owner;

create policy bride_portal_owner on public.bride
  for select to portal_owner
  using (portal_token_hash is not null and deleted_at is null);
create policy course_portal_owner on public.course
  for select to portal_owner
  using (deleted_at is null);
create policy session_portal_owner on public.session
  for select to portal_owner
  using (deleted_at is null);

-- ---------- access_log: portal_owner may append bride_portal rows only ----------
grant insert on public.access_log to portal_owner;
-- The policy's subquery reads bride.id/tenant_id under portal_owner's own
-- bride policy above, i.e. a live, token-bearing bride of that tenant.
create policy access_log_portal_insert on public.access_log
  for insert to portal_owner
  with check (
    actor_kind = 'bride_portal'
    and bride_id is not null
    and actor_id is not distinct from bride_id
    and exists (select 1 from public.bride b
                where b.id = access_log.bride_id
                  and b.tenant_id = access_log.tenant_id)
  );

-- ---------- portal_rate_limit: reachable by portal_owner only ----------
grant select, insert, update on public.portal_rate_limit to portal_owner;
create policy portal_rate_limit_portal_owner on public.portal_rate_limit
  for all to portal_owner
  using (true) with check (true);

-- ---------- portal_resolve_token ----------
create function public.portal_resolve_token(
  p_token_hash bytea,
  p_request_id uuid
)
returns table (
  bride_id          uuid,
  tenant_id         uuid,
  first_name        text,
  portal_expires_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $fn$
#variable_conflict use_column
begin
  if p_token_hash is null or pg_catalog.octet_length(p_token_hash) operator(pg_catalog.<>) 32 then
    raise exception 'portal_resolve_token: p_token_hash must be a 32-byte sha256'
      using errcode = '22023';
  end if;
  if p_request_id is null then
    raise exception 'portal_resolve_token: p_request_id is required'
      using errcode = '22023';
  end if;

  -- ONE statement: the row returned and the log row written together.
  return query
  with resolved as (
    select v.id, v.tenant_id, v.first_name, v.portal_expires_at
    from public.portal_bride_view v
    where v.portal_token_hash = p_token_hash
  ),
  logged as (
    insert into public.access_log
      (tenant_id, actor_kind, actor_id, bride_id, action, resource, request_id)
    select r.tenant_id, 'bride_portal', r.id, r.id,
           'read', 'portal_resolve_token', p_request_id::pg_catalog.text
    from resolved r
  )
  select r.id, r.tenant_id, r.first_name, r.portal_expires_at
  from resolved r;
end
$fn$;

-- ---------- portal_sessions ----------
create function public.portal_sessions(
  p_token_hash bytea,
  p_request_id uuid
)
returns setof public.portal_session_view
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $fn$
begin
  if p_token_hash is null or pg_catalog.octet_length(p_token_hash) operator(pg_catalog.<>) 32 then
    raise exception 'portal_sessions: p_token_hash must be a 32-byte sha256'
      using errcode = '22023';
  end if;
  if p_request_id is null then
    raise exception 'portal_sessions: p_request_id is required'
      using errcode = '22023';
  end if;

  return query
  with resolved as (
    select v.id, v.tenant_id
    from public.portal_bride_view v
    where v.portal_token_hash = p_token_hash
  ),
  logged as (
    insert into public.access_log
      (tenant_id, actor_kind, actor_id, bride_id, action, resource, request_id)
    select r.tenant_id, 'bride_portal', r.id, r.id,
           'read', 'portal_sessions', p_request_id::pg_catalog.text
    from resolved r
  )
  select s.id, s.bride_id, s.order_index, s.scheduled_at,
         s.duration_minutes, s.location, s.status
  from public.portal_session_view s
  join resolved r on r.id = s.bride_id
  order by s.order_index, s.scheduled_at, s.id;
end
$fn$;

-- ---------- portal_rate_limit_hit: same interface, definer rights ----------
create or replace function public.portal_rate_limit_hit(
  p_client_ip_hmac    bytea,
  p_token_hash_prefix bytea,
  p_window_seconds    integer
)
returns table (
  ip_hits                integer,
  token_hash_prefix_hits integer,
  window_ends_at         timestamptz
)
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $fn$
declare
  v_start      pg_catalog.timestamptz;
  v_ip_hits    pg_catalog.int4;
  v_pref_hits  pg_catalog.int4;
begin
  if p_client_ip_hmac is null and p_token_hash_prefix is null then
    raise exception 'portal_rate_limit_hit: at least one bucket key is required'
      using errcode = '22023';
  end if;
  if p_window_seconds is null or p_window_seconds not between 1 and 86400 then
    raise exception 'portal_rate_limit_hit: p_window_seconds must be 1..86400'
      using errcode = '22023';
  end if;

  v_start := pg_catalog.date_bin(pg_catalog.make_interval(secs => p_window_seconds), pg_catalog.now(),
                                 '1970-01-01 00:00:00+00'::pg_catalog.timestamptz);

  if p_client_ip_hmac is not null then
    insert into public.portal_rate_limit (client_ip_hmac, window_seconds, window_start)
    values (p_client_ip_hmac, p_window_seconds, v_start)
    on conflict (client_ip_hmac, window_seconds, window_start) where client_ip_hmac is not null
    do update set hits = public.portal_rate_limit.hits + 1
    returning hits into v_ip_hits;
  end if;

  if p_token_hash_prefix is not null then
    insert into public.portal_rate_limit (token_hash_prefix, window_seconds, window_start)
    values (p_token_hash_prefix, p_window_seconds, v_start)
    on conflict (token_hash_prefix, window_seconds, window_start) where token_hash_prefix is not null
    do update set hits = public.portal_rate_limit.hits + 1
    returning hits into v_pref_hits;
  end if;

  return query select v_ip_hits, v_pref_hits,
                      v_start operator(pg_catalog.+) pg_catalog.make_interval(secs => p_window_seconds);
end
$fn$;

comment on function public.portal_resolve_token(bytea, uuid) is
  'Portal token resolution (issue #53, ADR-0010): sha256 of the token in, at most '
  'one bride out, and one (bride_portal) access_log row written in the same '
  'statement. SECURITY DEFINER owned by portal_owner (NOBYPASSRLS). The hash is '
  'the only row selector. Executable by portal_reader only.';
comment on function public.portal_sessions(bytea, uuid) is
  'The bride portal''s session list (issue #53, ADR-0010): portal_session_view''s '
  'seven columns for the bride the token hash resolves to, and one (bride_portal) '
  'access_log row in the same statement. Executable by portal_reader only.';
comment on function public.portal_rate_limit_hit(bytea, bytea, integer) is
  'Increment the per-IP-HMAC and per-token-hash-prefix fixed-window counters '
  'and return both counts (SDD 6.2, issues #37, #53). SECURITY DEFINER owned by '
  'portal_owner; executable by portal_reader only. Decides nothing; limits live '
  'in lib/data/portal.ts.';

-- ---------- hand-over to portal_owner ----------
-- Postgres requires the new owner to hold CREATE on the schema; portal_owner
-- gets it for exactly these statements and no longer (0006).
grant  create on schema public to portal_owner;
alter function public.portal_resolve_token(bytea, uuid)              owner to portal_owner;
alter function public.portal_sessions(bytea, uuid)                   owner to portal_owner;
alter function public.portal_rate_limit_hit(bytea, bytea, integer)   owner to portal_owner;
revoke create on schema public from portal_owner;

-- ---------- EXECUTE: portal_reader and nobody else ----------
-- 0005 removed the platform's default EXECUTE for anon, authenticated and
-- PUBLIC, and this migration removed service_role's above, so these new
-- functions should carry no grant but the owner's. The revokes are stated
-- anyway: they make the intended ACL readable here, and they hold even on a
-- database whose default privileges drifted from what the migrations set.
revoke all on function public.portal_resolve_token(bytea, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.portal_sessions(bytea, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.portal_rate_limit_hit(bytea, bytea, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.portal_resolve_token(bytea, uuid)            to portal_reader;
grant execute on function public.portal_sessions(bytea, uuid)                 to portal_reader;
grant execute on function public.portal_rate_limit_hit(bytea, bytea, integer) to portal_reader;

-- prune: owner only (the pg_cron job), stated rather than inherited.
revoke all on function public.portal_rate_limit_prune()
  from public, anon, authenticated, service_role;

commit;
