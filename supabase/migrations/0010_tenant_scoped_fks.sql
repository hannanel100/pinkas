-- =============================================================
-- 0010 — tenant-scoped foreign keys: a row may only hang off an
--        object of its own tenant
-- Issue #55 (split out of #53). Relates to SDD §3 (data model), §4 (RLS),
-- ADR-0002. Extends the pattern 0006 point 6 applied to session_record.
--
-- Expand-only: no deployed code path writes a cross-tenant reference
-- (nothing legitimate can — RLS hides the other tenant's ids), so nothing
-- loses a path. No new objects in `public` beyond two unique constraints,
-- hence no grants (runbooks/migrations.md, "closed by default").
-- =============================================================
--
-- THE GAP
--
-- Four foreign keys referenced only an id:
--
--   course.bride_id                      -> bride(id)
--   session.course_id                    -> course(id)
--   payment.course_id                    -> course(id)
--   session.rescheduled_from_session_id  -> session(id)
--
-- Foreign-key checks run as the referenced table's owner and ignore RLS.
-- WITH CHECK forces the row's own tenant_id to be auth.uid(), but nothing
-- forced the REFERENCED row to share it. Tenant A could therefore
--   * learn whether a UUID exists in tenant B (FK error vs. success — an
--     existence oracle across tenants), and
--   * attach her own course/session/payment to B's bride/course/session —
--     invisible to B under RLS, but squatting on B's objects, and swept into
--     B's cascades (a hard delete of B's bride would delete A's course).
--
-- THE SHAPE
--
-- Each FK becomes (child_col, tenant_id) -> parent(id, tenant_id), so the
-- referenced row must exist AND belong to the same tenant. With tenant_id
-- NOT NULL, MATCH SIMPLE checks the pair whenever child_col is non-null —
-- exactly the cases the single-column FK checked — so the old FK is strictly
-- implied and is dropped. Dropping it is not tidiness: two FKs between the
-- same pair of tables make PostgREST resource embedding ambiguous (PGRST201,
-- `course?select=*,bride(*)` would need an explicit !hint).
--
-- Referential actions are unchanged:
--   course  -> bride   ON DELETE CASCADE
--   session -> course  ON DELETE CASCADE
--   payment -> course  ON DELETE CASCADE
--   session -> session ON DELETE SET NULL (rescheduled_from_session_id)
-- The last uses the PG15+ column list: a plain SET NULL on a composite key
-- would also null session.tenant_id (NOT NULL — the delete would fail).
-- Supabase runs PG15+; this file fails to parse on older servers.
--
-- Backing keys: unique (id, tenant_id) on bride and course (new here);
-- session_id_tenant_key on session already exists (0006).
--
-- PRE-CHECK — run on staging and prod BEFORE `supabase db push`
--
-- Expected result: zero rows. Any row is a cross-tenant reference that
-- exists today, i.e. evidence that the gap above was used (or a data bug).
-- Do NOT "fix" it by rewriting tenant_id and re-running: stop, treat it as a
-- potential privacy incident (PRD §10.1), and take it back to `database`
-- and `security`. The migration itself repeats this check and aborts with
-- the counts, atomically, if any row is found.
--
--   select 'course.bride_id' as fk, c.id as child_id, c.tenant_id, b.tenant_id as parent_tenant
--     from public.course c join public.bride b on b.id = c.bride_id
--    where b.tenant_id <> c.tenant_id
--   union all
--   select 'session.course_id', s.id, s.tenant_id, c.tenant_id
--     from public.session s join public.course c on c.id = s.course_id
--    where c.tenant_id <> s.tenant_id
--   union all
--   select 'payment.course_id', p.id, p.tenant_id, c.tenant_id
--     from public.payment p join public.course c on c.id = p.course_id
--    where c.tenant_id <> p.tenant_id
--   union all
--   select 'session.rescheduled_from_session_id', s.id, s.tenant_id, r.tenant_id
--     from public.session s join public.session r on r.id = s.rescheduled_from_session_id
--    where r.tenant_id <> s.tenant_id;
--
-- Inner joins suffice: the existing single-column FKs guarantee the parent
-- exists. Run as the migration role (it bypasses RLS); as `authenticated`
-- the query would only ever see one tenant and prove nothing.
--
-- LOCKS
--
-- The file is one transaction (as 0006), so every lock is held to COMMIT:
--   * ADD CONSTRAINT ... UNIQUE on bride, course: ACCESS EXCLUSIVE while the
--     index builds (CREATE INDEX CONCURRENTLY cannot run in a transaction).
--   * ADD FOREIGN KEY ... NOT VALID: SHARE ROW EXCLUSIVE on child and parent.
--   * VALIDATE CONSTRAINT: SHARE UPDATE EXCLUSIVE on the child, ROW SHARE on
--     the parent — but the stronger locks above are already held.
--   * DROP CONSTRAINT (old FK): ACCESS EXCLUSIVE on child and parent.
-- So NOT VALID + VALIDATE does not shorten the write outage inside one
-- transaction; it is kept so the pre-check can sit between them and abort
-- with a readable message, and so the two steps can be split across
-- transactions later if the tables ever grow enough to matter. At Phase 1
-- volumes (hundreds of rows per tenant) the whole file is milliseconds;
-- apply off-peak anyway — bride, course, session and payment are all
-- unwritable for its duration.
--
-- FOLLOW-UP (not in this migration — same gap, same fix):
--   message_log.bride_id, message_log.session_id, message_log.template_id,
--   material.course_id, material.curriculum_topic_id,
--   curriculum_topic.curriculum_id, course.curriculum_id.
--   The SET NULL ones (message_log.session_id/template_id,
--   material.curriculum_topic_id, course.curriculum_id) need the same
--   column-list form used below for rescheduled_from_session_id.
-- =============================================================

begin;

-- ---------- backing keys ----------
alter table public.bride
  add constraint bride_id_tenant_key unique (id, tenant_id);
alter table public.course
  add constraint course_id_tenant_key unique (id, tenant_id);
-- public.session already has session_id_tenant_key (0006)

-- ---------- composite FKs, unvalidated: new writes are checked from here ----------
alter table public.course
  add constraint course_bride_tenant_fk
  foreign key (bride_id, tenant_id) references public.bride (id, tenant_id)
  on delete cascade
  not valid;

alter table public.session
  add constraint session_course_tenant_fk
  foreign key (course_id, tenant_id) references public.course (id, tenant_id)
  on delete cascade
  not valid;

alter table public.payment
  add constraint payment_course_tenant_fk
  foreign key (course_id, tenant_id) references public.course (id, tenant_id)
  on delete cascade
  not valid;

alter table public.session
  add constraint session_rescheduled_from_tenant_fk
  foreign key (rescheduled_from_session_id, tenant_id) references public.session (id, tenant_id)
  on delete set null (rescheduled_from_session_id)
  not valid;

-- ---------- pre-check: the header query, as a guard with a readable failure ----------
do $$
declare
  n_course int; n_session int; n_payment int; n_resched int;
begin
  select count(*) into n_course
    from public.course c join public.bride b on b.id = c.bride_id
   where b.tenant_id <> c.tenant_id;
  select count(*) into n_session
    from public.session s join public.course c on c.id = s.course_id
   where c.tenant_id <> s.tenant_id;
  select count(*) into n_payment
    from public.payment p join public.course c on c.id = p.course_id
   where c.tenant_id <> p.tenant_id;
  select count(*) into n_resched
    from public.session s join public.session r on r.id = s.rescheduled_from_session_id
   where r.tenant_id <> s.tenant_id;

  if n_course + n_session + n_payment + n_resched > 0 then
    raise exception 'cross-tenant references exist: course.bride_id=%, session.course_id=%, payment.course_id=%, session.rescheduled_from_session_id=%',
      n_course, n_session, n_payment, n_resched
      using hint = 'Possible privacy incident. Do not rewrite tenant_id to make this pass; see the 0010 header.';
  end if;
end $$;

-- ---------- validate ----------
alter table public.course  validate constraint course_bride_tenant_fk;
alter table public.session validate constraint session_course_tenant_fk;
alter table public.payment validate constraint payment_course_tenant_fk;
alter table public.session validate constraint session_rescheduled_from_tenant_fk;

-- ---------- drop the single-column FKs the composite ones imply ----------
alter table public.course  drop constraint course_bride_id_fkey;
alter table public.session drop constraint session_course_id_fkey;
alter table public.payment drop constraint payment_course_id_fkey;
alter table public.session drop constraint session_rescheduled_from_session_id_fkey;

commit;
