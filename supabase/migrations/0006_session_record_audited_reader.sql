-- =============================================================
-- 0006 — session_record's private columns: revoke direct read,
--        read through an audited reader, write through an upsert
-- Issue #34 (settled in the #7 design challenge). Relates to SDD §5
-- (private/public boundary), §13 (data layer), §16.2 (support reads),
-- ADR-0002, ADR-0003, ADR-0006. Blocks #7 (lib/data/records.ts).
--
-- Expand-only for the code that exists today: no lib/data module reads or
-- writes session_record yet, so nothing deployed loses a path. #7 must be
-- written against the interface below, not against the table.
-- =============================================================
--
-- THE GAP
--
-- 0001 grants SELECT on session_record to `authenticated`, and PostgREST
-- exposes `public` unconditionally, so `GET /rest/v1/session_record?select=
-- private_note` with any valid instructor JWT returned every note in that
-- tenant and wrote zero access_log rows. Not cross-tenant (RLS held), but
-- invariant 3's "every read goes through lib/data/" was a property of this
-- repository, not of the deployment: a stolen session, or a support engineer
-- holding an impersonated JWT, could read note bodies off the record.
--
-- THE SHAPE
--
-- 1. Column-level revoke. `authenticated` keeps SELECT on session_id,
--    tenant_id, created_at, updated_at, deleted_at and loses it on exactly
--    covered_topic_ids, private_note, needs_review_note — the same three
--    names SDD §5.2 already confines to one relation. Invariant 2 is now
--    stated in privileges, not only in table structure. service_role gets
--    the same five-column grant: the portal path has no business with
--    session_record at all, and a direct service-key read of a note would
--    be precisely the unlogged support read §16.2 forbids.
--
-- 2. Reads: public.read_session_records(), SECURITY DEFINER, which returns
--    the private columns AND inserts the access_log rows in one SQL
--    statement (a data-modifying CTE). There is no way to receive a note
--    body from it without the log row being written in the same statement,
--    and no way to keep the rows if the log insert fails.
--
-- 3. The reader's OWNER is the part that must not be got wrong. A definer
--    function owned by `postgres` runs as the table owner, and RLS does not
--    apply to a table's owner (and live, postgres also holds BYPASSRLS): the
--    log would be bought by giving up invariant 1 on the most sensitive
--    table in the product. The owner is therefore a dedicated role,
--    session_record_reader, which is:
--      * NOLOGIN, NOBYPASSRLS, not a superuser, not the table owner;
--      * a member of `authenticated` — so the EXISTING policies written
--        `to authenticated` (session_record_tenant, session_tenant,
--        course_tenant, access_log_insert) apply to it verbatim, and
--        auth.uid() still resolves from the caller's JWT GUC;
--      * granted SELECT on exactly the three private columns — the only
--        thing it can do that `authenticated` cannot.
--    The function deliberately carries NO `tenant_id = auth.uid()`
--    predicate of its own: schema.test.sql's cross-tenant assertion must
--    measure RLS, and an extra predicate would let that test pass with the
--    owner wrong.
--
-- 4. Writes: public.upsert_session_record(), SECURITY INVOKER. Found while
--    exercising the write path rather than reasoning about it: plain
--    INSERT and `UPDATE ... WHERE session_id = ...` survive the column
--    revoke, but PostgREST's upsert (supabase-js `.upsert()`, i.e.
--    Prefer: resolution=merge-duplicates) generates `ON CONFLICT DO UPDATE
--    SET private_note = EXCLUDED.private_note`, and reading EXCLUDED.<col>
--    requires SELECT on <col>. That shape now fails with 42501. The
--    function upserts from its parameters instead, which needs only
--    INSERT/UPDATE, runs as the caller under RLS, and stays atomic.
--
-- 5. access_log: `actor_kind = 'instructor'` now requires
--    `actor_id = tenant_id`. instructor.id = auth.users.id = tenant_id
--    (SDD §3.2), so a genuine instructor row always satisfies it and a
--    support read forged as `instructor` must also forge actor_id. Written
--    with IS NOT DISTINCT FROM so a NULL actor_id cannot slip through as
--    UNKNOWN: an instructor row attributable to nobody is rejected.
--
-- INTERFACE FOR lib/data/records.ts (#7)
--
--   read:   supabase.rpc('read_session_records',
--             { p_session_ids: string[], p_request_id: string /* uuid */ })
--           -> rows { session_id, course_id, bride_id, order_index,
--                     covered_topic_ids, private_note, needs_review_note,
--                     updated_at }, ordered by course_id, order_index.
--           * Must be POST (supabase-js .rpc() default). The function is
--             VOLATILE because it writes; a GET runs read-only and fails.
--           * Writes one access_log row per distinct bride disclosed:
--             action 'read', resource 'session_record', request_id =
--             p_request_id. records.ts must NOT also call logAccess() for
--             the same read — the database has already logged it.
--           * Actor is derived from the verified JWT, never a parameter:
--             no `impersonated_by` claim -> ('instructor', auth.uid());
--             top-level `impersonated_by: <uuid>` -> ('support', that uuid).
--             A present but non-uuid claim is refused (28000).
--           * Rows for ids the caller cannot see are silently absent and
--             produce no log row. Soft-deleted records, sessions or courses
--             are excluded. An empty or null array returns nothing.
--           * No JWT -> 28000.
--   write:  supabase.rpc('upsert_session_record',
--             { p_session_id, p_covered_topic_ids, p_private_note,
--               p_needs_review_note })
--           -> one row { session_id, created_at, updated_at }.
--           * Full replace of the three private fields; NULL clears a note,
--             NULL topic list is stored as '{}'. tenant_id is auth.uid(),
--             never a parameter. deleted_at is not touched.
--           * Session not visible to the caller (another tenant's, or
--             soft-deleted) -> P0002. Writes no access_log row: §10.1 logs
--             viewing, and nothing private is returned.
--           * Never `.upsert()` / `.select('private_note')` on the table:
--             both now fail with 42501, by design.
--
-- 6. Composite foreign key (session_id, tenant_id) -> session(id,
--    tenant_id). Foreign-key checks ignore RLS, so the single-column FK let
--    a tenant INSERT a record (under her own tenant_id) hanging off another
--    tenant's session id — no disclosure, but a row squatting on someone
--    else's primary key, blocking that tenant's own record for the session.
--    The pair must now agree. Backed by a unique (id, tenant_id) on session.
--
-- APPLYING THIS ON A LIVE PROJECT (PR #51 review)
--
-- The whole file is one explicit transaction. On a non-superuser migration
-- role, a failure partway through without it would commit the earlier
-- steps — and the observed partial state was read_session_records as
-- SECURITY DEFINER owned by the MIGRATION role, which holds BYPASSRLS: the
-- exact state point 3 forbids. With the transaction it is all or nothing.
--
-- Two privileges a superuser never notices are needed, and CI exercises both
-- (SCHEMA_TEST_AS_MIGRATOR=1 ./scripts/test-schema.sh, a non-superuser
-- CREATEROLE + BYPASSRLS role that owns the database):
--   * ADMIN on `authenticated`, to grant it to session_record_reader.
--     PG16+ no longer lets CREATEROLE alone grant membership in a role it
--     did not create. Check BEFORE `supabase db push`, as the migration role:
--
--       select admin_option from pg_auth_members
--        where roleid = 'authenticated'::regrole
--          and member = 'postgres'::regrole;
--
--     It must return one row, `t`. No row or `f` means this migration will
--     fail (atomically) on that project: stop and take it back to
--     `database` — do not work around it by changing the owner.
--   * CREATE on schema `public` for the NEW OWNER at the moment of
--     ALTER FUNCTION ... OWNER TO (Postgres checks the new owner could have
--     created it). Granted immediately before the hand-over and revoked
--     immediately after, inside the same transaction; schema.test.sql
--     asserts the role holds no CREATE afterwards. Requires the migration
--     role to be able to grant CREATE on `public` — it can when it owns the
--     database (`public` is owned by pg_database_owner):
--
--       select has_schema_privilege('postgres', 'public', 'CREATE WITH GRANT OPTION');
-- =============================================================

begin;

-- ---------- the owner role ----------
do $$
declare r pg_roles%rowtype;
begin
  select * into r from pg_roles where rolname = 'session_record_reader';
  if not found then
    -- NOBYPASSRLS is the default; stated so the intent is greppable.
    create role session_record_reader nologin nobypassrls;
  elsif r.rolbypassrls or r.rolsuper or r.rolcanlogin then
    -- Roles are cluster-wide and may pre-exist. Never adopt one that could
    -- bypass RLS or be logged into; fail the migration instead.
    raise exception
      'session_record_reader exists with bypassrls=%, superuser=%, login=% — refusing to own the note reader with it',
      r.rolbypassrls, r.rolsuper, r.rolcanlogin;
  end if;
end $$;

comment on role session_record_reader is
  'Owner of public.read_session_records() (issue #34). NOLOGIN, NOBYPASSRLS, '
  'member of authenticated so the tenant policies apply; may additionally '
  'SELECT session_record''s three private columns. Never make it the owner '
  'of a table, and never grant it BYPASSRLS.';

-- Membership in authenticated is how RLS and auth.uid() reach the reader.
grant authenticated to session_record_reader;
-- The migration role must be able to SET ROLE to the new owner to hand the
-- function over (ALTER ... OWNER TO) on a platform where it is not a
-- superuser. Grants the migration role nothing it did not already hold.
grant session_record_reader to current_user;

-- ---------- column-level privileges on session_record ----------
-- REVOKE at table level also strips any column-level SELECT, so the
-- re-grant must come after it.
revoke select on public.session_record from authenticated, service_role, anon;
grant  select (session_id, tenant_id, created_at, updated_at, deleted_at)
       on public.session_record to authenticated, service_role;
grant  select (covered_topic_ids, private_note, needs_review_note)
       on public.session_record to session_record_reader;

-- ---------- session_record's tenant must be its session's tenant ----------
alter table public.session
  add constraint session_id_tenant_key unique (id, tenant_id);
alter table public.session_record
  add constraint session_record_session_tenant_fk
  foreign key (session_id, tenant_id) references public.session (id, tenant_id)
  on delete cascade;

-- ---------- access_log: an instructor row is attributed to the tenant ----------
alter table public.access_log
  add constraint access_log_instructor_actor_ck
  check (actor_kind <> 'instructor' or actor_id is not distinct from tenant_id);

-- ---------- the audited reader ----------
create function public.read_session_records(
  p_session_ids uuid[],
  p_request_id  uuid default null
)
returns table (
  session_id        uuid,
  course_id         uuid,
  bride_id          uuid,
  order_index       smallint,
  covered_topic_ids uuid[],
  private_note      text,
  needs_review_note text,
  updated_at        timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
#variable_conflict use_column
declare
  v_uid        uuid := auth.uid();
  v_claims     jsonb;
  v_actor_kind text;
  v_actor_id   uuid;
begin
  if v_uid is null then
    raise exception 'read_session_records: requires an authenticated caller'
      using errcode = '28000';
  end if;

  v_claims := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
  if v_claims ? 'impersonated_by' then
    begin
      v_actor_id := (v_claims ->> 'impersonated_by')::uuid;
    exception when invalid_text_representation then
      v_actor_id := null;
    end;
    if v_actor_id is null then
      raise exception 'read_session_records: impersonated_by must be a uuid'
        using errcode = '28000';
    end if;
    v_actor_kind := 'support';
  else
    v_actor_kind := 'instructor';
    v_actor_id   := v_uid;
  end if;

  -- ONE statement: the rows returned and the access_log rows written are
  -- produced together. A data-modifying CTE always runs to completion
  -- whether or not the outer query reads it, and if the insert fails the
  -- whole statement — and so the read — fails with it.
  return query
  with disclosed as (
    select sr.session_id, s.course_id, c.bride_id, sr.tenant_id, s.order_index,
           sr.covered_topic_ids, sr.private_note, sr.needs_review_note, sr.updated_at
    from public.session_record sr
    join public.session s on s.id = sr.session_id
    join public.course  c on c.id = s.course_id
    where sr.session_id = any (p_session_ids)
      and sr.deleted_at is null
      and s.deleted_at  is null
      and c.deleted_at  is null
  ),
  logged as (
    insert into public.access_log
      (tenant_id, actor_kind, actor_id, bride_id, action, resource, request_id)
    select d.tenant_id, v_actor_kind, v_actor_id, d.bride_id,
           'read', 'session_record', p_request_id::text
    from disclosed d
    group by d.tenant_id, d.bride_id
  )
  select d.session_id, d.course_id, d.bride_id, d.order_index,
         d.covered_topic_ids, d.private_note, d.needs_review_note, d.updated_at
  from disclosed d
  order by d.course_id, d.order_index;
end
$fn$;

-- Hand-over. Postgres requires the new owner to hold CREATE on the schema;
-- the reader role gets it for exactly this statement and no longer.
grant  create on schema public to session_record_reader;
alter function public.read_session_records(uuid[], uuid) owner to session_record_reader;
revoke create on schema public from session_record_reader;

comment on function public.read_session_records(uuid[], uuid) is
  'The only read path to session_record''s private columns (issue #34). '
  'SECURITY DEFINER owned by session_record_reader (NOBYPASSRLS): tenant RLS '
  'still applies. Writes one access_log row per bride disclosed, in the same '
  'statement as the read. Call via POST; interface in migration 0006.';

revoke execute on function public.read_session_records(uuid[], uuid) from public, anon, service_role;
grant  execute on function public.read_session_records(uuid[], uuid) to authenticated;

-- ---------- the write path ----------
create function public.upsert_session_record(
  p_session_id        uuid,
  p_covered_topic_ids uuid[],
  p_private_note      text,
  p_needs_review_note text
)
returns table (
  session_id uuid,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
volatile
security invoker
set search_path = ''
as $fn$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'upsert_session_record: requires an authenticated caller'
      using errcode = '28000';
  end if;

  -- Foreign-key checks run as the table owner and ignore RLS, so without
  -- this a tenant could attach a record (under her own tenant_id) to
  -- another tenant's session id. Visibility under the caller's RLS is the
  -- test; a soft-deleted session takes no new notes.
  if not exists (select 1 from public.session s
                 where s.id = p_session_id and s.deleted_at is null) then
    raise exception 'upsert_session_record: session not found'
      using errcode = 'P0002';
  end if;

  -- Values come from the parameters, never EXCLUDED.<col>: reading EXCLUDED
  -- needs SELECT on the column, which `authenticated` no longer holds.
  return query
  insert into public.session_record as sr
    (session_id, tenant_id, covered_topic_ids, private_note, needs_review_note)
  values
    (p_session_id, v_uid, coalesce(p_covered_topic_ids, '{}'::uuid[]),
     p_private_note, p_needs_review_note)
  on conflict (session_id) do update
    set covered_topic_ids = coalesce(p_covered_topic_ids, '{}'::uuid[]),
        private_note      = p_private_note,
        needs_review_note = p_needs_review_note
  returning sr.session_id, sr.created_at, sr.updated_at;
end
$fn$;

comment on function public.upsert_session_record(uuid, uuid[], text, text) is
  'Write path for session_record (issue #34): SECURITY INVOKER, tenant is '
  'auth.uid(). Exists because PostgREST upserts read EXCLUDED.<col>, which '
  'needs the column SELECT that 0006 revokes. Interface in migration 0006.';

revoke execute on function public.upsert_session_record(uuid, uuid[], text, text) from public, anon, service_role;
grant  execute on function public.upsert_session_record(uuid, uuid[], text, text) to authenticated;

commit;
