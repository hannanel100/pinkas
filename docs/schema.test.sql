-- =============================================================
-- Verification: tenant isolation, portal surface, risk tiers
-- Any failure raises and aborts (psql -v ON_ERROR_STOP=1).
-- =============================================================
\set A '''a0000000-0000-4000-8000-000000000001'''
\set B '''b0000000-0000-4000-8000-000000000002'''

-- ---------- seed as superuser (bypasses RLS) ----------
insert into instructor (id, full_name, phone) values
  (:A, 'Michal (tenant A)', '050-0000001'),
  (:B, 'Sara  (tenant B)',  '050-0000002');

insert into bride (id, tenant_id, first_name, wedding_date, status) values
  ('a1000000-0000-4000-8000-000000000001', :A, 'Noa',   current_date + 34, 'active'),
  ('b1000000-0000-4000-8000-000000000001', :B, 'Rivka', current_date + 60, 'active');

insert into course (id, tenant_id, bride_id, curriculum_snapshot, target_end_date, status) values
  ('a2000000-0000-4000-8000-000000000001', :A, 'a1000000-0000-4000-8000-000000000001', '{"topics":[]}', current_date + 20, 'active'),
  ('b2000000-0000-4000-8000-000000000001', :B, 'b1000000-0000-4000-8000-000000000001', '{"topics":[]}', current_date + 46, 'active');

insert into session (id, tenant_id, course_id, order_index, scheduled_at, location, status) values
  ('a3000000-0000-4000-8000-000000000001', :A, 'a2000000-0000-4000-8000-000000000001', 1, now() + interval '1 day', 'Herzl 14', 'planned'),
  ('b3000000-0000-4000-8000-000000000001', :B, 'b2000000-0000-4000-8000-000000000001', 1, now() + interval '2 day', 'Weizmann 3', 'planned');

insert into session_record (session_id, tenant_id, private_note, needs_review_note) values
  ('a3000000-0000-4000-8000-000000000001', :A, 'A private note', 'A review note'),
  ('b3000000-0000-4000-8000-000000000001', :B, 'B private note', 'B review note');

-- risk-tier fixtures, all under tenant A
insert into bride (id, tenant_id, first_name, wedding_date, status) values
  ('a1000000-0000-4000-8000-0000000000c1', :A, 'Crit',   current_date + 28,  'active'),
  ('a1000000-0000-4000-8000-0000000000d1', :A, 'High',   current_date + 214, 'active'),
  ('a1000000-0000-4000-8000-0000000000e1', :A, 'Med',    current_date + 214, 'active'),
  ('a1000000-0000-4000-8000-0000000000f1', :A, 'Info',   current_date + 20,  'active'),
  ('a1000000-0000-4000-8000-00000000000b', :A, 'None',   current_date + 214, 'active');

insert into course (id, tenant_id, bride_id, curriculum_snapshot, target_end_date, status) values
  ('a2000000-0000-4000-8000-0000000000c1', :A, 'a1000000-0000-4000-8000-0000000000c1', '{}', current_date + 14,  'active'),
  ('a2000000-0000-4000-8000-0000000000d1', :A, 'a1000000-0000-4000-8000-0000000000d1', '{}', current_date + 200, 'active'),
  ('a2000000-0000-4000-8000-0000000000e1', :A, 'a1000000-0000-4000-8000-0000000000e1', '{}', current_date + 200, 'active'),
  ('a2000000-0000-4000-8000-0000000000f1', :A, 'a1000000-0000-4000-8000-0000000000f1', '{}', current_date + 6,   'active'),
  ('a2000000-0000-4000-8000-00000000000b', :A, 'a1000000-0000-4000-8000-00000000000b', '{}', current_date + 200, 'active');

-- critical: 5 sessions left, only 2 whole weeks to the deadline
insert into session (tenant_id, course_id, order_index, scheduled_at, status)
select :A, 'a2000000-0000-4000-8000-0000000000c1', g, now() + (g || ' day')::interval, 'planned'
from generate_series(1,5) g;

-- high: a cancellation older than 7 days that was never rescheduled
insert into session (tenant_id, course_id, order_index, scheduled_at, status) values
  (:A, 'a2000000-0000-4000-8000-0000000000d1', 1, now() - interval '10 days', 'cancelled'),
  (:A, 'a2000000-0000-4000-8000-0000000000d1', 2, now() + interval '3 days',  'planned');

-- medium: last completed session was more than 21 days ago
insert into session (tenant_id, course_id, order_index, scheduled_at, status) values
  (:A, 'a2000000-0000-4000-8000-0000000000e1', 1, now() - interval '30 days', 'done'),
  (:A, 'a2000000-0000-4000-8000-0000000000e1', 2, now() + interval '3 days',  'planned');

-- info: nothing outstanding, but the wedding is inside 30 days
insert into session (tenant_id, course_id, order_index, scheduled_at, status) values
  (:A, 'a2000000-0000-4000-8000-0000000000f1', 1, now() - interval '2 days', 'done');

-- none: healthy course
insert into session (tenant_id, course_id, order_index, scheduled_at, status) values
  (:A, 'a2000000-0000-4000-8000-00000000000b', 1, now() - interval '2 days', 'done'),
  (:A, 'a2000000-0000-4000-8000-00000000000b', 2, now() + interval '3 days', 'planned');

-- =============================================================
-- Switch to an ordinary authenticated user acting as tenant A
-- =============================================================
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';

do $$
declare n int; txt text;
begin
  -- auth.uid() resolves
  if auth.uid() is null then
    raise exception 'FAIL: auth.uid() did not resolve from the JWT claim';
  end if;

  -- 1. tenant A sees only its own brides
  select count(*) into n from bride;
  if n <> 6 then raise exception 'FAIL: tenant A sees % brides, expected 6 (its own)', n; end if;

  -- 2. tenant B's bride is invisible even when addressed by primary key
  select count(*) into n from bride where id = 'b1000000-0000-4000-8000-000000000001';
  if n <> 0 then raise exception 'FAIL: tenant A read tenant B bride by id'; end if;

  -- 3. private records are isolated
  select count(*) into n from session_record;
  if n <> 1 then raise exception 'FAIL: tenant A sees % session_records, expected 1', n; end if;

  -- #34: the private columns are no longer directly readable at all; that
  -- private_note never crosses tenants is asserted through the audited
  -- reader in the "#31 / #34" section below.
  begin
    select count(*) into n from session_record where private_note like 'B %';
    raise exception 'FAIL: authenticated can read session_record.private_note directly';
  exception when insufficient_privilege then null;
  end;

  -- 4. views respect the caller's RLS (this is what security_invoker buys)
  select count(*) into n from v_course_risk;
  if n <> 6 then raise exception 'FAIL: v_course_risk leaked across tenants (% rows)', n; end if;

  select count(*) into n from portal_session_view where bride_id = 'b1000000-0000-4000-8000-000000000001';
  if n <> 0 then raise exception 'FAIL: portal_session_view leaked tenant B rows'; end if;

  -- 5. writes cannot be attributed to another tenant
  begin
    insert into bride (tenant_id, first_name) values ('b0000000-0000-4000-8000-000000000002', 'Injected');
    raise exception 'FAIL: WITH CHECK allowed an insert under a foreign tenant_id';
  exception when insufficient_privilege then null;
  end;

  -- 6. updates to another tenant's row affect nothing
  update bride set first_name = 'Hacked' where id = 'b1000000-0000-4000-8000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: updated % of tenant B rows', n; end if;

  -- 7. access_log is append-only for instructors
  insert into access_log (tenant_id, actor_kind, actor_id, bride_id, action, resource)
    values (auth.uid(), 'instructor', auth.uid(),
            'a1000000-0000-4000-8000-000000000001', 'read', 'bride');
  begin
    delete from access_log;
    raise exception 'FAIL: access_log rows were deletable';
  exception when insufficient_privilege then null;
  end;

  raise notice 'PASS: tenant isolation, view invocation, write-side checks, append-only log';
end $$;

-- =============================================================
-- Portal surface: the column list is the contract (ADR-0003)
-- =============================================================
do $$
declare cols text; n int;
begin
  select string_agg(column_name, ',' order by ordinal_position) into cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'portal_session_view';

  if cols <> 'id,bride_id,order_index,scheduled_at,duration_minutes,location,status' then
    raise exception 'FAIL: portal_session_view surface changed -> %', cols;
  end if;

  -- the three private fields must exist in exactly one relation: session_record
  select count(distinct table_name) into n
  from information_schema.columns
  where table_schema = 'public'
    and column_name in ('private_note','needs_review_note','covered_topic_ids');
  if n <> 1 then
    raise exception 'FAIL: private fields are exposed by % relations, expected 1', n;
  end if;

  raise notice 'PASS: portal exposes exactly 7 non-private columns; private fields confined to session_record';
end $$;

-- =============================================================
-- Risk tiers (§9)
-- =============================================================
do $$
declare r record; got text;
begin
  for r in
    select * from (values
      ('a2000000-0000-4000-8000-0000000000c1','critical','wont_finish_in_time'),
      ('a2000000-0000-4000-8000-0000000000d1','high','cancelled_not_rescheduled'),
      ('a2000000-0000-4000-8000-0000000000e1','medium','no_recent_session'),
      ('a2000000-0000-4000-8000-0000000000f1','info','wedding_approaching'),
      ('a2000000-0000-4000-8000-00000000000b','none',null)
    ) as t(course_id, want_level, want_reason)
  loop
    select risk_level::text || '/' || coalesce(risk_reason_code,'-') into got
    from v_course_risk where course_id = r.course_id::uuid;

    if got is distinct from (r.want_level || '/' || coalesce(r.want_reason,'-')) then
      raise exception 'FAIL: course % ranked %, expected %/%',
        r.course_id, got, r.want_level, coalesce(r.want_reason,'-');
    end if;
  end loop;
  raise notice 'PASS: all five risk tiers rank as specified in §9';
end $$;

reset role;

-- =============================================================
-- BEGIN #36 — bootstrap_instructor: the signup seed is atomic
-- Requires migration 0002_bootstrap_instructor_atomic.sql.
-- =============================================================
-- Tenants used below: C = c0000000-0000-4000-8000-000000000003 (clean signup),
-- D = d0000000-0000-4000-8000-000000000004 (signup that fails partway).
-- Written out literally rather than as psql variables: psql does not
-- interpolate :vars inside the dollar-quoted DO blocks that follow.

-- Carries ids between role switches so the cross-tenant check below can
-- address a seeded row by primary key, not only by tenant_id.
create temp table bootstrap36 (label text primary key, id uuid);
grant all on bootstrap36 to authenticated;

-- ---------- shape: the properties that make it safe, not just correct ----------
do $$
declare f pg_proc%rowtype;
begin
  select * into f from pg_proc
  where oid = to_regprocedure('public.bootstrap_instructor(text,text,jsonb,text,jsonb)');
  if f.oid is null then
    raise exception 'FAIL: bootstrap_instructor(text,text,jsonb,text,jsonb) is missing';
  end if;

  -- security definer would bypass RLS for every row the seed writes, turning
  -- the signup helper into a tenant-forgery primitive (invariant 1).
  if f.prosecdef then
    raise exception 'FAIL: bootstrap_instructor is SECURITY DEFINER';
  end if;

  -- a procedure can COMMIT mid-body; that is precisely the partial state
  -- this ticket exists to make impossible.
  if f.prokind <> 'f' then
    raise exception 'FAIL: bootstrap_instructor is not a plain function (prokind=%)', f.prokind;
  end if;

  if f.proconfig is null
     or not exists (select 1 from unnest(f.proconfig) c where c like 'search_path=%') then
    raise exception 'FAIL: bootstrap_instructor does not pin search_path';
  end if;

  -- no instructor-id parameter: the tenant can only ever be auth.uid()
  if exists (select 1 from unnest(f.proargnames) a
             where a in ('p_id','p_instructor_id','p_tenant_id')) then
    raise exception 'FAIL: bootstrap_instructor takes a caller-supplied tenant id';
  end if;

  if not has_function_privilege('authenticated', f.oid, 'execute') then
    raise exception 'FAIL: authenticated cannot execute bootstrap_instructor';
  end if;
  if has_function_privilege('service_role', f.oid, 'execute') then
    raise exception 'FAIL: service_role can execute bootstrap_instructor (invariant 5)';
  end if;
  if has_function_privilege('anon', f.oid, 'execute') then
    raise exception 'FAIL: anon can execute bootstrap_instructor';
  end if;
  if exists (select 1 from aclexplode(f.proacl) a where a.grantee = 0) then
    raise exception 'FAIL: bootstrap_instructor is executable by PUBLIC';
  end if;

  raise notice 'PASS: bootstrap_instructor is invoker-rights, a function, search_path-pinned, granted only to authenticated';
end $$;

-- ---------- happy path, as a brand-new tenant C ----------
set role authenticated;
set request.jwt.claims = '{"sub":"c0000000-0000-4000-8000-000000000003"}';

do $$
declare r record; n int; ord text;
begin
  select * into r from public.bootstrap_instructor(
    'Chana (tenant C)',
    '+972500000003',
    '[{"name":"reminder","body":"hi {{bride_name}} - {{date}} {{time}} {{location}}"},
      {"name":"welcome","body":"welcome {{bride_name}} - {{instructor_name}}"}]'::jsonb,
    'chana@example.test',
    '{"name":"C starter","description":"seeded template",
      "topics":[{"title":"Topic one","estimated_minutes":60},{"title":"Topic two"}]}'::jsonb);

  if r.instructor_id <> 'c0000000-0000-4000-8000-000000000003' then
    raise exception 'FAIL: bootstrap returned instructor_id %, expected auth.uid()', r.instructor_id;
  end if;
  if not r.was_created then raise exception 'FAIL: was_created false on first bootstrap'; end if;
  if r.seeded_template_count <> 2 then
    raise exception 'FAIL: seeded % templates, expected 2', r.seeded_template_count;
  end if;
  if r.seeded_curriculum_id is null then raise exception 'FAIL: no curriculum seeded'; end if;

  insert into bootstrap36 values ('curriculum', r.seeded_curriculum_id);

  -- every seeded row is tenant-scoped from the moment it exists (invariant 1)
  select count(*) into n from instructor where id = auth.uid();
  if n <> 1 then raise exception 'FAIL: instructor row not visible to its own tenant'; end if;

  select count(*) into n from message_template where tenant_id = auth.uid() and is_system;
  if n <> 2 then raise exception 'FAIL: % system templates for tenant C, expected 2', n; end if;

  select count(*) into n from message_template where tenant_id = auth.uid() and not is_system;
  if n <> 0 then raise exception 'FAIL: bootstrap seeded % non-system templates', n; end if;

  select count(*) into n from curriculum where tenant_id = auth.uid();
  if n <> 1 then raise exception 'FAIL: % curricula for tenant C, expected 1', n; end if;

  select count(*) into n from curriculum where id = r.seeded_curriculum_id and default_session_count = 2;
  if n <> 1 then raise exception 'FAIL: default_session_count was not derived from the topic count'; end if;

  select string_agg(order_index::text, ',' order by order_index) into ord
  from curriculum_topic where curriculum_id = r.seeded_curriculum_id and tenant_id = auth.uid();
  if ord is distinct from '1,2' then
    raise exception 'FAIL: seeded topic order_index list is %, expected 1,2', ord;
  end if;

  -- invariant 6: bootstrap seeds a *template*. A course (and its snapshot) is
  -- created later, from it — never here.
  select count(*) into n from course where tenant_id = auth.uid();
  if n <> 0 then raise exception 'FAIL: bootstrap created % course rows', n; end if;

  raise notice 'PASS: bootstrap seeds instructor + system templates + curriculum template, all tenant-scoped';
end $$;

-- ---------- a retry must not double-seed ----------
do $$
declare r record; n int;
begin
  select * into r from public.bootstrap_instructor(
    'Chana again', '+972500000003',
    '[{"name":"reminder","body":"second attempt"}]'::jsonb,
    null,
    '{"name":"C starter again","topics":[{"title":"Topic three"}]}'::jsonb);

  if r.was_created then raise exception 'FAIL: second bootstrap reported a fresh instructor'; end if;
  if r.seeded_template_count <> 0 then
    raise exception 'FAIL: second bootstrap seeded % more templates', r.seeded_template_count;
  end if;
  if r.seeded_curriculum_id is not null then
    raise exception 'FAIL: second bootstrap seeded another curriculum';
  end if;

  select count(*) into n from message_template where tenant_id = auth.uid();
  if n <> 2 then raise exception 'FAIL: tenant C now has % templates, expected 2', n; end if;
  select count(*) into n from curriculum where tenant_id = auth.uid();
  if n <> 1 then raise exception 'FAIL: tenant C now has % curricula, expected 1', n; end if;
  select count(*) into n from curriculum_topic where tenant_id = auth.uid();
  if n <> 2 then raise exception 'FAIL: tenant C now has % topics, expected 2', n; end if;
  select count(*) into n from instructor where full_name = 'Chana again';
  if n <> 0 then raise exception 'FAIL: second bootstrap overwrote the instructor row'; end if;

  raise notice 'PASS: bootstrap is idempotent - a retry seeds only what is missing';
end $$;

-- ---------- an unauthenticated caller gets nothing ----------
set request.jwt.claims = '{}';
do $$
begin
  perform * from public.bootstrap_instructor(
    'Nobody', '+972500000000', '[{"name":"x","body":"y"}]'::jsonb);
  raise exception 'FAIL: bootstrap ran without an authenticated caller';
exception when sqlstate '28000' then null;
end $$;

-- ---------- tenant A cannot see anything tenant C was seeded ----------
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
do $$
declare n int;
begin
  select count(*) into n from curriculum
   where id = (select id from bootstrap36 where label = 'curriculum');
  if n <> 0 then raise exception 'FAIL: tenant A read tenant C curriculum by primary key'; end if;

  select count(*) into n from curriculum
   where tenant_id = 'c0000000-0000-4000-8000-000000000003';
  if n <> 0 then raise exception 'FAIL: tenant A sees % of tenant C curricula', n; end if;

  select count(*) into n from curriculum_topic
   where curriculum_id = (select id from bootstrap36 where label = 'curriculum');
  if n <> 0 then raise exception 'FAIL: tenant A sees tenant C curriculum topics'; end if;

  select count(*) into n from message_template
   where tenant_id = 'c0000000-0000-4000-8000-000000000003';
  if n <> 0 then raise exception 'FAIL: tenant A sees tenant C message templates'; end if;

  select count(*) into n from instructor
   where id = 'c0000000-0000-4000-8000-000000000003';
  if n <> 0 then raise exception 'FAIL: tenant A read tenant C instructor row'; end if;

  raise notice 'PASS: the bootstrapped rows are invisible to another tenant, including by primary key';
end $$;

-- ---------- atomicity: a failure partway leaves nothing behind ----------
-- estimated_minutes = 0 trips curriculum_topic's CHECK on the *last* insert
-- the function performs, i.e. after the instructor row, the templates and the
-- curriculum row have all been written.
set request.jwt.claims = '{"sub":"d0000000-0000-4000-8000-000000000004"}';
do $$
begin
  perform * from public.bootstrap_instructor(
    'Dvora (tenant D)', '+972500000004',
    '[{"name":"reminder","body":"hi {{bride_name}}"},{"name":"welcome","body":"welcome"}]'::jsonb,
    null,
    '{"name":"D starter","topics":[{"title":"Fine"},{"title":"Broken","estimated_minutes":0}]}'::jsonb);
  raise exception 'FAIL: bootstrap accepted a topic violating estimated_minutes > 0';
exception when check_violation then null;
end $$;

-- Counted as superuser: RLS must not be the reason the rows look absent.
reset role;
do $$
declare n int;
begin
  select count(*) into n from instructor where id = 'd0000000-0000-4000-8000-000000000004';
  if n <> 0 then raise exception 'FAIL: a failed bootstrap left an instructor row behind'; end if;
  select count(*) into n from message_template where tenant_id = 'd0000000-0000-4000-8000-000000000004';
  if n <> 0 then raise exception 'FAIL: a failed bootstrap left % templates behind', n; end if;
  select count(*) into n from curriculum where tenant_id = 'd0000000-0000-4000-8000-000000000004';
  if n <> 0 then raise exception 'FAIL: a failed bootstrap left a curriculum behind'; end if;
  select count(*) into n from curriculum_topic where tenant_id = 'd0000000-0000-4000-8000-000000000004';
  if n <> 0 then raise exception 'FAIL: a failed bootstrap left curriculum topics behind'; end if;
end $$;

-- The same payload with the one bad value corrected must succeed. Without
-- this, the assertions above would also pass if the call had failed at the
-- very first statement and proved nothing about partial state.
set role authenticated;
set request.jwt.claims = '{"sub":"d0000000-0000-4000-8000-000000000004"}';
do $$
declare r record;
begin
  select * into r from public.bootstrap_instructor(
    'Dvora (tenant D)', '+972500000004',
    '[{"name":"reminder","body":"hi {{bride_name}}"},{"name":"welcome","body":"welcome"}]'::jsonb,
    null,
    '{"name":"D starter","topics":[{"title":"Fine"},{"title":"Fixed","estimated_minutes":45}]}'::jsonb);
  if not r.was_created then
    raise exception 'FAIL: the rolled-back bootstrap had left an instructor row after all';
  end if;
  if r.seeded_template_count <> 2 or r.seeded_curriculum_id is null then
    raise exception 'FAIL: the corrected payload did not seed the full account';
  end if;
end $$;

reset role;
do $$
declare n int;
begin
  select count(*) into n from curriculum_topic
   where tenant_id = 'd0000000-0000-4000-8000-000000000004';
  if n <> 2 then raise exception 'FAIL: tenant D has % topics after a clean bootstrap, expected 2', n; end if;
  raise notice 'PASS: a bootstrap that fails partway leaves no instructor, template, curriculum or topic behind';
end $$;

drop table bootstrap36;
-- =============================================================
-- END #36
-- =============================================================

-- =============================================================
-- BEGIN #38 + #42 — v_course_risk: the Asia/Jerusalem clock, and no tier
-- without a deadline
-- Requires migration 0003_risk_clock_and_null_deadline.sql.
-- =============================================================
-- Tenant E = 38000000-0000-4000-8000-0000000000e0. Its boundary fixtures use
-- FIXED dates in 2030 and call course_risk(p_today) directly, so every
-- boundary is pinned to a known civil date instead of depending on when the
-- suite runs. The view itself is then checked to be course_risk(<Israeli today>).
--
-- The Israeli-midnight instants used below:
--   2030-03-01 22:30Z = 2030-03-02 00:30 in Jerusalem (IST, UTC+2) — UTC date 03-01
--   2030-07-01 21:30Z = 2030-07-02 00:30 in Jerusalem (IDT, UTC+3) — UTC date 07-01
-- Every boundary fixture is chosen so that the UTC reading gives a DIFFERENT
-- answer: reverting to `current_date` / `now()` arithmetic fails this block.

reset role;
set timezone = 'UTC';   -- what a Supabase session runs under

insert into instructor (id, full_name, phone) values
  ('38000000-0000-4000-8000-0000000000e0', 'Esther (tenant E, #38/#42)', '050-0000038');

insert into bride (id, tenant_id, first_name, wedding_date, status) values
  -- #42: no deadline, no wedding date
  ('38100000-0000-4000-8000-000000000001', '38000000-0000-4000-8000-0000000000e0', 'NoDeadline',    null,                        'active'),
  -- #42: no deadline, wedding close — must fall through to `info`, not `critical`
  ('38100000-0000-4000-8000-000000000002', '38000000-0000-4000-8000-0000000000e0', 'NoDeadlineWed', date '2030-03-20',           'active'),
  -- #38: critical boundary at Israeli midnight
  ('38100000-0000-4000-8000-000000000003', '38000000-0000-4000-8000-0000000000e0', 'CritEdge',      date '2030-06-01',           'active'),
  -- #38: stale-cancellation boundary
  ('38100000-0000-4000-8000-000000000004', '38000000-0000-4000-8000-0000000000e0', 'StaleEdge',     date '2031-06-01',           'active'),
  -- #38: no-recent-session boundary
  ('38100000-0000-4000-8000-000000000005', '38000000-0000-4000-8000-0000000000e0', 'MedEdge',       date '2031-06-01',           'active'),
  -- #38: the live view, relative to the real Israeli today
  ('38100000-0000-4000-8000-000000000006', '38000000-0000-4000-8000-0000000000e0', 'LiveClock',     jerusalem_date(now()) + 200, 'active'),
  -- soft-deleted bride with an active course: must not rank at all
  ('38100000-0000-4000-8000-000000000007', '38000000-0000-4000-8000-0000000000e0', 'DeletedBride',  null,                        'active');
update bride set deleted_at = now() where id = '38100000-0000-4000-8000-000000000007';

insert into course (id, tenant_id, bride_id, curriculum_snapshot, target_end_date, status) values
  ('38200000-0000-4000-8000-000000000001', '38000000-0000-4000-8000-0000000000e0', '38100000-0000-4000-8000-000000000001', '{}', null,                       'active'),
  ('38200000-0000-4000-8000-000000000002', '38000000-0000-4000-8000-0000000000e0', '38100000-0000-4000-8000-000000000002', '{}', null,                       'active'),
  ('38200000-0000-4000-8000-000000000003', '38000000-0000-4000-8000-0000000000e0', '38100000-0000-4000-8000-000000000003', '{}', date '2030-03-15',         'active'),
  ('38200000-0000-4000-8000-000000000004', '38000000-0000-4000-8000-0000000000e0', '38100000-0000-4000-8000-000000000004', '{}', date '2031-05-01',         'active'),
  ('38200000-0000-4000-8000-000000000005', '38000000-0000-4000-8000-0000000000e0', '38100000-0000-4000-8000-000000000005', '{}', date '2031-05-01',         'active'),
  ('38200000-0000-4000-8000-000000000006', '38000000-0000-4000-8000-0000000000e0', '38100000-0000-4000-8000-000000000006', '{}', jerusalem_date(now()) + 20, 'active'),
  ('38200000-0000-4000-8000-000000000007', '38000000-0000-4000-8000-0000000000e0', '38100000-0000-4000-8000-000000000007', '{}', null,                       'active');

insert into session (tenant_id, course_id, order_index, scheduled_at, status) values
  -- no-deadline courses with sessions remaining: exactly what used to trip `critical`
  ('38000000-0000-4000-8000-0000000000e0', '38200000-0000-4000-8000-000000000001', 1, null, 'planned'),
  ('38000000-0000-4000-8000-0000000000e0', '38200000-0000-4000-8000-000000000001', 2, null, 'planned'),
  ('38000000-0000-4000-8000-0000000000e0', '38200000-0000-4000-8000-000000000001', 3, null, 'planned'),
  ('38000000-0000-4000-8000-0000000000e0', '38200000-0000-4000-8000-000000000002', 1, null, 'planned'),
  ('38000000-0000-4000-8000-0000000000e0', '38200000-0000-4000-8000-000000000002', 2, null, 'planned'),
  -- CritEdge: 2 planned, deadline 2030-03-15.
  --   Israeli today 03-02 -> 13 days -> 1 whole week  -> 2 > 1 -> critical
  --   UTC today     03-01 -> 14 days -> 2 whole weeks -> 2 > 2 false -> none
  ('38000000-0000-4000-8000-0000000000e0', '38200000-0000-4000-8000-000000000003', 1, null, 'planned'),
  ('38000000-0000-4000-8000-0000000000e0', '38200000-0000-4000-8000-000000000003', 2, null, 'planned'),
  -- StaleEdge: cancelled at 2030-03-01 22:30Z = Israeli 03-02. Never rescheduled.
  ('38000000-0000-4000-8000-0000000000e0', '38200000-0000-4000-8000-000000000004', 1, timestamptz '2030-03-01 22:30:00+00', 'cancelled'),
  -- MedEdge: last done at 2030-03-01 22:30Z = Israeli 03-02.
  ('38000000-0000-4000-8000-0000000000e0', '38200000-0000-4000-8000-000000000005', 1, timestamptz '2030-03-01 22:30:00+00', 'done'),
  -- LiveClock: 1 planned, deadline 20 Israeli days out -> none
  ('38000000-0000-4000-8000-0000000000e0', '38200000-0000-4000-8000-000000000006', 1, null, 'planned'),
  ('38000000-0000-4000-8000-0000000000e0', '38200000-0000-4000-8000-000000000007', 1, null, 'planned');

-- ---------- the clock itself ----------
do $$
begin
  if jerusalem_date('2030-03-01 22:30:00+00') <> date '2030-03-02' then
    raise exception 'FAIL: jerusalem_date at Israeli midnight (IST) gave %, expected 2030-03-02',
      jerusalem_date('2030-03-01 22:30:00+00');
  end if;
  if jerusalem_date('2030-07-01 21:30:00+00') <> date '2030-07-02' then
    raise exception 'FAIL: jerusalem_date at Israeli midnight (IDT) gave %, expected 2030-07-02',
      jerusalem_date('2030-07-01 21:30:00+00');
  end if;
  if jerusalem_date('2030-03-01 21:59:59+00') <> date '2030-03-01' then
    raise exception 'FAIL: jerusalem_date one second before Israeli midnight crossed the day';
  end if;
  -- the session timezone must not leak into it
  set local timezone = 'Pacific/Kiritimati';
  if jerusalem_date('2030-03-01 22:30:00+00') <> date '2030-03-02' then
    raise exception 'FAIL: jerusalem_date depends on the session timezone';
  end if;
  raise notice 'PASS: jerusalem_date resolves Israeli civil dates at both DST offsets, independent of the session timezone';
end $$;

-- ---------- structure: one clock, invoker-rights, narrowly granted ----------
do $$
declare def text; f record; v record;
begin
  -- the view must be course_risk(jerusalem_date(now())) and read no other clock
  def := pg_get_viewdef('public.v_course_risk'::regclass, true);
  if def ilike '%current_date%' or def not ilike '%jerusalem_date(now())%' then
    raise exception 'FAIL: v_course_risk is not computed against jerusalem_date(now()): %', def;
  end if;

  select prosrc, prosecdef into f from pg_proc where oid = 'public.course_risk(date)'::regprocedure;
  if f.prosrc ilike '%current_date%' or f.prosrc ilike '%now()%'
     or f.prosrc ilike '%localtimestamp%' or f.prosrc ilike '%current_timestamp%' then
    raise exception 'FAIL: course_risk reads an ambient clock; it must use p_today only';
  end if;
  if f.prosecdef then
    raise exception 'FAIL: course_risk is SECURITY DEFINER - it would bypass RLS';
  end if;

  -- every view in public stays security_invoker (SDD §4.2)
  for v in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'
      and not coalesce(c.reloptions @> array['security_invoker=on'], false)
      and not coalesce(c.reloptions @> array['security_invoker=true'], false)
  loop
    raise exception 'FAIL: view % is not security_invoker', v.relname;
  end loop;

  for f in
    select p.oid, p.oid::regprocedure::text as sig from pg_proc p
    where p.oid in ('public.course_risk(date)'::regprocedure,
                    'public.jerusalem_date(timestamptz)'::regprocedure)
  loop
    if not has_function_privilege('authenticated', f.oid, 'execute') then
      raise exception 'FAIL: authenticated cannot execute % (v_course_risk would break)', f.sig;
    end if;
    if has_function_privilege('anon', f.oid, 'execute') then
      raise exception 'FAIL: anon can execute %', f.sig;
    end if;
    if has_function_privilege('service_role', f.oid, 'execute') then
      raise exception 'FAIL: service_role can execute % (invariant 5)', f.sig;
    end if;
  end loop;

  raise notice 'PASS: v_course_risk has one clock (jerusalem_date), course_risk is invoker-rights, all views security_invoker';
end $$;

-- ---------- tier boundaries, pinned to Israeli civil dates ----------
set role authenticated;
set request.jwt.claims = '{"sub":"38000000-0000-4000-8000-0000000000e0"}';

do $$
declare r record; got text; israeli date; utc date;
begin
  israeli := jerusalem_date('2030-03-01 22:30:00+00');                        -- 2030-03-02
  utc     := (timestamptz '2030-03-01 22:30:00+00' at time zone 'UTC')::date; -- 2030-03-01

  -- #38: critical fires on the Israeli date and not on the UTC one
  select risk_level || '/' || days_to_deadline into got
  from course_risk(israeli) where course_id = '38200000-0000-4000-8000-000000000003';
  if got is distinct from 'critical/13' then
    raise exception 'FAIL: CritEdge on the Israeli date ranked %, expected critical/13', got;
  end if;
  select risk_level || '/' || days_to_deadline into got
  from course_risk(utc) where course_id = '38200000-0000-4000-8000-000000000003';
  if got is distinct from 'none/14' then
    raise exception 'FAIL: CritEdge fixture is not discriminating (UTC date ranked %)', got;
  end if;

  -- #38: stale_cancellations counts Israeli civil days, strictly more than 7.
  -- Cancelled on Israeli 03-02: not stale on 03-09 (exactly 7), stale on 03-10.
  -- The UTC reading (03-01) would already call it stale on 03-09.
  select stale_cancellations || '/' || risk_level into got
  from course_risk(date '2030-03-09') where course_id = '38200000-0000-4000-8000-000000000004';
  if got is distinct from '0/none' then
    raise exception 'FAIL: cancellation exactly 7 Israeli days old counted stale (%)', got;
  end if;
  select stale_cancellations || '/' || risk_level into got
  from course_risk(date '2030-03-10') where course_id = '38200000-0000-4000-8000-000000000004';
  if got is distinct from '1/high' then
    raise exception 'FAIL: cancellation 8 Israeli days old not counted stale (%)', got;
  end if;

  -- #38: no_recent_session counts Israeli civil days, strictly more than 21.
  -- Done on Israeli 03-02: not medium on 03-23 (exactly 21), medium on 03-24.
  select risk_level::text into got
  from course_risk(date '2030-03-23') where course_id = '38200000-0000-4000-8000-000000000005';
  if got is distinct from 'none' then
    raise exception 'FAIL: exactly 21 Israeli days since last session ranked %', got;
  end if;
  select risk_level::text into got
  from course_risk(date '2030-03-24') where course_id = '38200000-0000-4000-8000-000000000005';
  if got is distinct from 'medium' then
    raise exception 'FAIL: 22 Israeli days since last session ranked %, expected medium', got;
  end if;

  -- #42: no deadline -> no `critical`, days_to_deadline NULL (never 0)
  for r in
    select * from (values
      ('38200000-0000-4000-8000-000000000001', 'none/-'),
      ('38200000-0000-4000-8000-000000000002', 'info/wedding_approaching')
    ) as t(course_id, want)
  loop
    select risk_level || '/' || coalesce(risk_reason_code, '-')
           || case when days_to_deadline is null then '' else '/days=' || days_to_deadline end
      into got
    from course_risk(date '2030-03-02') where course_id = r.course_id::uuid;
    if got is distinct from r.want then
      raise exception 'FAIL (#42): no-deadline course % ranked %, expected % with NULL days_to_deadline',
        r.course_id, got, r.want;
    end if;
  end loop;

  -- soft-deleted bride: her course does not rank
  if exists (select 1 from course_risk(date '2030-03-02')
             where course_id = '38200000-0000-4000-8000-000000000007') then
    raise exception 'FAIL: a soft-deleted bride''s course still ranks';
  end if;

  raise notice 'PASS: tier boundaries resolve in Israeli civil days; a course with no deadline is not critical and reports NULL days';
end $$;

-- ---------- the live view: Israeli today, whatever the session timezone ----------
-- Pacific/Kiritimati (UTC+14) and Etc/GMT+12 (UTC-12) are 26 hours apart, so
-- their `current_date`s ALWAYS differ. A view that read the session clock
-- cannot give both sessions the same days_to_deadline; this one must.
do $$
declare a int; b int; n int;
begin
  set local timezone = 'Pacific/Kiritimati';
  select days_to_deadline into a from v_course_risk where course_id = '38200000-0000-4000-8000-000000000006';
  set local timezone = 'Etc/GMT+12';
  select days_to_deadline into b from v_course_risk where course_id = '38200000-0000-4000-8000-000000000006';
  -- LiveClock's deadline was seeded as jerusalem_date(now()) + 20
  if a is distinct from 20 or b is distinct from 20 then
    raise exception 'FAIL: v_course_risk days_to_deadline depends on the session timezone (UTC+14: %, UTC-12: %, want 20)', a, b;
  end if;

  -- #42 through the view: the null deadline is null, never 0, never critical
  select count(*) into n from v_course_risk
  where course_id in ('38200000-0000-4000-8000-000000000001', '38200000-0000-4000-8000-000000000002')
    and (days_to_deadline is not null or risk_level = 'critical');
  if n <> 0 then
    raise exception 'FAIL (#42): v_course_risk reports a deadline-less course as critical or with a day count';
  end if;

  -- the view is exactly course_risk on the Israeli date
  select count(*) into n from (
    (select * from v_course_risk except select * from course_risk(jerusalem_date(now())))
    union all
    (select * from course_risk(jerusalem_date(now())) except select * from v_course_risk)
  ) diff;
  if n <> 0 then
    raise exception 'FAIL: v_course_risk differs from course_risk(jerusalem_date(now())) in % rows', n;
  end if;

  -- RLS applies inside the function: tenant E sees only its own rows
  select count(*) into n from course_risk(jerusalem_date(now()))
  where tenant_id <> '38000000-0000-4000-8000-0000000000e0';
  if n <> 0 then raise exception 'FAIL: course_risk leaked % rows across tenants', n; end if;

  raise notice 'PASS: v_course_risk counts days on the Israeli clock regardless of session timezone';
end $$;

-- tenant A cannot reach tenant E's rows through the function either
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
do $$
declare n int;
begin
  select count(*) into n from course_risk(date '2030-03-02')
  where course_id = '38200000-0000-4000-8000-000000000003';
  if n <> 0 then raise exception 'FAIL: tenant A read tenant E risk by course_id'; end if;
  select count(*) into n from course_risk(jerusalem_date(now()));
  if n <> 6 then raise exception 'FAIL: tenant A sees % course_risk rows, expected its own 6', n; end if;
  raise notice 'PASS: course_risk is tenant-isolated by RLS, including by course_id';
end $$;

-- ---------- the nightly job's reading (§8.4) ----------
-- pg_cron runs as the database owner, outside any JWT, in a UTC session, and
-- reads v_course_risk directly. Assert the corrected tiers from exactly that
-- position: superuser, no claims, a session timezone far from Israel.
reset role;
reset request.jwt.claims;
do $$
declare r record; got text;
begin
  set local timezone = 'Etc/GMT+12';
  for r in
    select * from (values
      -- the original five §8.1 fixtures (tenant A)
      ('a2000000-0000-4000-8000-0000000000c1','critical/wont_finish_in_time'),
      ('a2000000-0000-4000-8000-0000000000d1','high/cancelled_not_rescheduled'),
      ('a2000000-0000-4000-8000-0000000000e1','medium/no_recent_session'),
      ('a2000000-0000-4000-8000-0000000000f1','info/wedding_approaching'),
      ('a2000000-0000-4000-8000-00000000000b','none/-'),
      -- #42 (tenant E)
      -- (no wedding, no deadline, three sessions left: 0001 called this critical)
      ('38200000-0000-4000-8000-000000000001','none/-')
    ) as t(course_id, want)
  loop
    select risk_level || '/' || coalesce(risk_reason_code, '-') into got
    from v_course_risk where course_id = r.course_id::uuid;
    if got is distinct from r.want then
      raise exception 'FAIL: nightly-job read of course % gave %, expected %', r.course_id, got, r.want;
    end if;
  end loop;

  select days_to_deadline::text into got from v_course_risk
  where course_id = '38200000-0000-4000-8000-000000000006';
  if got is distinct from '20' then
    raise exception 'FAIL: nightly-job read of LiveClock gave % days, expected 20', got;
  end if;

  raise notice 'PASS: the nightly job''s position (owner, no JWT, foreign session timezone) reads the corrected tiers';
end $$;
reset timezone;
-- =============================================================
-- END #38 + #42
-- =============================================================

-- =============================================================
-- BEGIN #35 — today_screen: one aggregated query, one access_log fan-out
-- Requires migrations 0003 (course_risk) and 0004_today_screen.sql.
-- =============================================================
-- Tenants (literal: psql does not interpolate :vars inside DO blocks):
--   F = 35000000-0000-4000-8000-0000000000f0  the caller
--   G = 35000000-0000-4000-8000-0000000000a0  another tenant, must never appear
--   H = 35000000-0000-4000-8000-0000000000b0  a tenant with no brides yet
-- p_today = 2030-05-10 (Israel is on IDT, UTC+3). Sessions sit on both sides
-- of Israeli midnight so the UTC reading of "today" selects different rows.

reset role;
reset request.jwt.claims;
set timezone = 'UTC';

insert into instructor (id, full_name, phone) values
  ('35000000-0000-4000-8000-0000000000f0', 'Fruma (tenant F, #35)', '050-0000035'),
  ('35000000-0000-4000-8000-0000000000a0', 'Gila (tenant G, #35)',  '050-0000036'),
  ('35000000-0000-4000-8000-0000000000b0', 'Hadas (tenant H, #35)', '050-0000037');

insert into bride (id, tenant_id, first_name, last_name, phone, wedding_date, status) values
  -- F1: active course, session today, stale cancellation, open balance
  ('35100000-0000-4000-8000-0000000000f1', '35000000-0000-4000-8000-0000000000f0', 'Avigail', 'Peretz',  '+972500000351', date '2030-07-15', 'active'),
  -- F2: active course with no deadline, session just after Israeli midnight, fully paid
  ('35100000-0000-4000-8000-0000000000f2', '35000000-0000-4000-8000-0000000000f0', 'Racheli', 'Mizrahi', '+972500000352', date '2030-08-01', 'active'),
  -- F3: completed course with an open balance only
  ('35100000-0000-4000-8000-0000000000f3', '35000000-0000-4000-8000-0000000000f0', 'Tamar',   'Aviv',    '+972500000353', date '2030-03-01', 'completed'),
  -- F4: active course whose only session is TOMORROW in Israel (today in UTC)
  ('35100000-0000-4000-8000-0000000000f4', '35000000-0000-4000-8000-0000000000f0', 'Shira',   'Levi',    '+972500000354', date '2030-10-01', 'active'),
  -- F5: a lead with no course — nothing about her is in the document
  ('35100000-0000-4000-8000-0000000000f5', '35000000-0000-4000-8000-0000000000f0', 'Leah',    null,      '+972500000355', null,             'lead'),
  -- F6: soft-deleted, with an active course, a session today and a balance
  ('35100000-0000-4000-8000-0000000000f6', '35000000-0000-4000-8000-0000000000f0', 'Deleted', null,      '+972500000356', date '2030-06-01', 'active'),
  -- G1: tenant G's bride, shaped to appear in every section if RLS failed
  ('35100000-0000-4000-8000-0000000000a1', '35000000-0000-4000-8000-0000000000a0', 'Gviria',  'Other',   '+972500000361', date '2030-05-20', 'active');
update bride set deleted_at = now() where id = '35100000-0000-4000-8000-0000000000f6';

insert into course (id, tenant_id, bride_id, curriculum_snapshot, target_end_date, agreed_price, status) values
  ('35200000-0000-4000-8000-0000000000f1', '35000000-0000-4000-8000-0000000000f0', '35100000-0000-4000-8000-0000000000f1', '{}', date '2030-06-30', 3000, 'active'),
  ('35200000-0000-4000-8000-0000000000f2', '35000000-0000-4000-8000-0000000000f0', '35100000-0000-4000-8000-0000000000f2', '{}', null,              1000, 'active'),
  ('35200000-0000-4000-8000-0000000000f3', '35000000-0000-4000-8000-0000000000f0', '35100000-0000-4000-8000-0000000000f3', '{}', date '2030-02-15', 2000, 'completed'),
  ('35200000-0000-4000-8000-0000000000f4', '35000000-0000-4000-8000-0000000000f0', '35100000-0000-4000-8000-0000000000f4', '{}', date '2030-09-01', null, 'active'),
  ('35200000-0000-4000-8000-0000000000f6', '35000000-0000-4000-8000-0000000000f0', '35100000-0000-4000-8000-0000000000f6', '{}', date '2030-05-20', 900,  'active'),
  -- F1's earlier, cancelled course: owes nothing on this screen
  ('35200000-0000-4000-8000-0000000000f7', '35000000-0000-4000-8000-0000000000f0', '35100000-0000-4000-8000-0000000000f1', '{}', date '2030-01-01', 5000, 'cancelled'),
  ('35200000-0000-4000-8000-0000000000a1', '35000000-0000-4000-8000-0000000000a0', '35100000-0000-4000-8000-0000000000a1', '{}', date '2030-05-15', 4000, 'active');

insert into session (id, tenant_id, course_id, order_index, scheduled_at, location, status) values
  -- F1: done, stale-cancelled (Israeli 05-02: stale on 05-10, not on 05-09), today, future
  ('35300000-0000-4000-8000-0000000000f1', '35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f1', 1, timestamptz '2030-05-01 15:00:00+00', 'Herzl 14', 'done'),
  ('35300000-0000-4000-8000-0000000000f2', '35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f1', 2, timestamptz '2030-05-02 10:00:00+00', 'Herzl 14', 'cancelled'),
  ('35300000-0000-4000-8000-0000000000f3', '35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f1', 3, timestamptz '2030-05-10 14:00:00+00', 'Herzl 14', 'planned'),
  ('35300000-0000-4000-8000-0000000000f4', '35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f1', 4, timestamptz '2030-05-17 14:00:00+00', 'Herzl 14', 'planned'),
  -- F2: 2030-05-09 21:30Z = 05-10 00:30 in Israel -> TODAY (UTC would say yesterday)
  ('35300000-0000-4000-8000-0000000000f5', '35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f2', 1, timestamptz '2030-05-09 21:30:00+00', 'Zoom',     'planned'),
  -- F4: 2030-05-10 21:30Z = 05-11 00:30 in Israel -> NOT today (UTC would say today)
  ('35300000-0000-4000-8000-0000000000f6', '35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f4', 1, timestamptz '2030-05-10 21:30:00+00', null,       'planned'),
  -- F1 today but cancelled: not a meeting that is happening
  ('35300000-0000-4000-8000-0000000000f7', '35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f1', 5, timestamptz '2030-05-10 08:00:00+00', null,       'cancelled'),
  -- F6 (deleted bride): today
  ('35300000-0000-4000-8000-0000000000f8', '35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f6', 1, timestamptz '2030-05-10 09:00:00+00', null,       'planned'),
  -- G1: today
  ('35300000-0000-4000-8000-0000000000a1', '35000000-0000-4000-8000-0000000000a0', '35200000-0000-4000-8000-0000000000a1', 1, timestamptz '2030-05-10 12:00:00+00', 'Elsewhere', 'planned');

insert into payment (tenant_id, course_id, amount, currency, method, paid_at) values
  ('35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f1', 1000, 'ILS', 'bit',      date '2030-05-01'),
  ('35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f1',  500, 'ILS', 'check',    date '2030-05-20'),  -- post-dated: not paid yet on 05-10
  ('35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f1',  100, 'USD', 'transfer', date '2030-05-01'),  -- foreign currency: excluded, counted
  ('35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f2', 1000, 'ILS', 'cash',     date '2030-04-01'),  -- F2 fully paid
  ('35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f3',  600, 'ILS', 'cash',     date '2030-01-10'),
  ('35000000-0000-4000-8000-0000000000a0', '35200000-0000-4000-8000-0000000000a1',  250, 'ILS', 'cash',     date '2030-05-01');
-- F8: a completed course fully paid in ILS, plus one USD payment. She owes
-- nothing and is in no list, but her USD payment is counted into
-- other_currency_payment_count, so her data IS in the document and she must
-- be logged (security review of #35).
insert into bride (id, tenant_id, first_name, status) values
  ('35100000-0000-4000-8000-0000000000f8', '35000000-0000-4000-8000-0000000000f0', 'Paid', 'completed');
insert into course (id, tenant_id, bride_id, curriculum_snapshot, target_end_date, agreed_price, status) values
  ('35200000-0000-4000-8000-0000000000f8', '35000000-0000-4000-8000-0000000000f0', '35100000-0000-4000-8000-0000000000f8', '{}', date '2030-01-01', 800, 'completed');
insert into payment (tenant_id, course_id, amount, currency, method, paid_at) values
  ('35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f8', 800, 'ILS', 'cash',     date '2029-12-01'),
  ('35000000-0000-4000-8000-0000000000f0', '35200000-0000-4000-8000-0000000000f8',  50, 'USD', 'transfer', date '2029-12-01');
-- Expected for F on 2030-05-10: F1 owes 3000-1000 = 2000, F3 owes 2000-600 = 1400
-- -> outstanding_total 3400.00 over 2 courses / 2 brides; 2 foreign-currency
-- payments (F1's and F8's).

-- ---------- shape: invoker-rights function, pinned search_path, narrow grants ----------
do $$
declare f pg_proc%rowtype;
begin
  select * into f from pg_proc where oid = to_regprocedure('public.today_screen(date,text)');
  if f.oid is null then raise exception 'FAIL: today_screen(date, text) is missing'; end if;
  if f.prosecdef then
    raise exception 'FAIL: today_screen is SECURITY DEFINER - RLS would not apply (invariant 1)';
  end if;
  if f.prokind <> 'f' then raise exception 'FAIL: today_screen is not a plain function'; end if;
  if f.prorettype <> 'jsonb'::regtype then raise exception 'FAIL: today_screen does not return jsonb'; end if;
  if f.proconfig is null
     or not exists (select 1 from unnest(f.proconfig) c where c like 'search_path=%') then
    raise exception 'FAIL: today_screen does not pin search_path';
  end if;
  if exists (select 1 from unnest(f.proargnames) a where a in ('p_id','p_instructor_id','p_tenant_id')) then
    raise exception 'FAIL: today_screen takes a caller-supplied tenant id';
  end if;
  if not has_function_privilege('authenticated', f.oid, 'execute') then
    raise exception 'FAIL: authenticated cannot execute today_screen';
  end if;
  if has_function_privilege('anon', f.oid, 'execute') then
    raise exception 'FAIL: anon can execute today_screen';
  end if;
  if has_function_privilege('service_role', f.oid, 'execute') then
    raise exception 'FAIL: service_role can execute today_screen (invariant 5)';
  end if;
  if exists (select 1 from aclexplode(f.proacl) a where a.grantee = 0) then
    raise exception 'FAIL: today_screen is executable by PUBLIC';
  end if;
  raise notice 'PASS: today_screen is invoker-rights, returns jsonb, search_path-pinned, granted only to authenticated';
end $$;

-- ---------- the document, as tenant F ----------
set role authenticated;
set request.jwt.claims = '{"sub":"35000000-0000-4000-8000-0000000000f0"}';

create temp table today35 (label text primary key, doc jsonb);

do $$
declare doc jsonb; got text; c jsonb; s jsonb;
begin
  doc := today_screen(date '2030-05-10', '35500000-0000-4000-8000-000000000510');
  insert into today35 values ('f0510', doc);

  -- top-level and per-element key sets are the contract (lib/data/today.ts)
  select string_agg(k, ',' order by k) into got from jsonb_object_keys(doc) k;
  if got <> 'courses,payments,sessions_today,timezone,today' then
    raise exception 'FAIL: today_screen top-level keys changed -> %', got;
  end if;
  if doc ->> 'today' <> '2030-05-10' or doc ->> 'timezone' <> 'Asia/Jerusalem' then
    raise exception 'FAIL: today/timezone not echoed (% / %)', doc ->> 'today', doc ->> 'timezone';
  end if;

  -- courses: the aggregate, never the verdict
  if jsonb_typeof(doc -> 'courses') <> 'array' then raise exception 'FAIL: courses is not an array'; end if;
  for c in select * from jsonb_array_elements(doc -> 'courses') loop
    select string_agg(k, ',' order by k) into got from jsonb_object_keys(c) k;
    if got <> 'bride_first_name,bride_id,bride_last_name,course_id,last_done_at,last_done_on,'
              'sessions_done,sessions_remaining,stale_cancellations,target_end_date,wedding_date' then
      raise exception 'FAIL: courses[] keys changed -> %', got;
    end if;
    if c ? 'risk_level' or c ? 'risk_reason_code' or c ? 'days_to_deadline' then
      raise exception 'FAIL: today_screen returned the risk verdict, not the aggregate';
    end if;
  end loop;

  -- every active course of a live bride, in order: target_end_date nulls last
  select string_agg(e ->> 'course_id', ',' order by ord) into got
  from jsonb_array_elements(doc -> 'courses') with ordinality as t(e, ord);
  if got is distinct from '35200000-0000-4000-8000-0000000000f1,'
                          '35200000-0000-4000-8000-0000000000f4,'
                          '35200000-0000-4000-8000-0000000000f2' then
    raise exception 'FAIL: courses list is %, expected F1, F4, F2 (active, live brides only)', got;
  end if;

  select e into c from jsonb_array_elements(doc -> 'courses') e
  where e ->> 'course_id' = '35200000-0000-4000-8000-0000000000f1';
  if (c ->> 'sessions_remaining')::int <> 2 or (c ->> 'sessions_done')::int <> 1
     or (c ->> 'stale_cancellations')::int <> 1
     or c ->> 'last_done_on' <> '2030-05-01'
     or c ->> 'target_end_date' <> '2030-06-30'
     or c ->> 'wedding_date' <> '2030-07-15'
     or c ->> 'bride_first_name' <> 'Avigail' then
    raise exception 'FAIL: F1 aggregate is wrong: %', c;
  end if;
  if jsonb_typeof(c -> 'sessions_remaining') <> 'number' then
    raise exception 'FAIL: counts must be JSON numbers';
  end if;

  select e into c from jsonb_array_elements(doc -> 'courses') e
  where e ->> 'course_id' = '35200000-0000-4000-8000-0000000000f2';
  if jsonb_typeof(c -> 'target_end_date') <> 'null' then
    raise exception 'FAIL: a missing deadline must arrive as JSON null (#42)';
  end if;

  -- sessions_today: the Israeli day, planned/done only, live brides only
  if jsonb_typeof(doc -> 'sessions_today') <> 'array' then raise exception 'FAIL: sessions_today is not an array'; end if;
  for s in select * from jsonb_array_elements(doc -> 'sessions_today') loop
    select string_agg(k, ',' order by k) into got from jsonb_object_keys(s) k;
    if got <> 'bride_first_name,bride_id,bride_last_name,bride_phone,course_id,duration_minutes,'
              'location,order_index,scheduled_at,session_id,status' then
      raise exception 'FAIL: sessions_today[] keys changed -> %', got;
    end if;
  end loop;
  select string_agg(e ->> 'session_id', ',' order by ord) into got
  from jsonb_array_elements(doc -> 'sessions_today') with ordinality as t(e, ord);
  if got is distinct from '35300000-0000-4000-8000-0000000000f5,35300000-0000-4000-8000-0000000000f3' then
    raise exception 'FAIL: sessions_today is %, expected F2 00:30 then F1 17:00 (Israeli day, not UTC day)', got;
  end if;

  -- payments: one number, as a decimal string
  select string_agg(k, ',' order by k) into got from jsonb_object_keys(doc -> 'payments') k;
  if got <> 'currency,open_bride_count,open_course_count,other_currency_payment_count,outstanding_total' then
    raise exception 'FAIL: payments keys changed -> %', got;
  end if;
  if jsonb_typeof(doc -> 'payments' -> 'outstanding_total') <> 'string' then
    raise exception 'FAIL: outstanding_total must be a decimal string, never a float';
  end if;
  got := concat_ws('/', doc #>> '{payments,currency}', doc #>> '{payments,outstanding_total}',
                   doc #>> '{payments,open_course_count}', doc #>> '{payments,open_bride_count}',
                   doc #>> '{payments,other_currency_payment_count}');
  if got <> 'ILS/3400.00/2/2/2' then
    raise exception 'FAIL: payments summary is %, expected ILS/3400.00/2/2/2', got;
  end if;

  raise notice 'PASS: today_screen returns risk aggregate, Israeli-day sessions and payment total in one documented jsonb shape';
end $$;

-- ---------- RLS: nothing of tenant G, by id or by content ----------
do $$
declare doc jsonb := (select doc from today35 where label = 'f0510');
begin
  if doc::text like '%35000000-0000-4000-8000-0000000000a0%'
     or doc::text like '%35100000-0000-4000-8000-0000000000a1%'
     or doc::text like '%35200000-0000-4000-8000-0000000000a1%'
     or doc::text like '%35300000-0000-4000-8000-0000000000a1%'
     or doc::text like '%Gviria%' or doc::text like '%Elsewhere%' then
    raise exception 'FAIL: tenant F''s today_screen contains tenant G data';
  end if;
  if doc::text like '%35100000-0000-4000-8000-0000000000f6%' or doc::text like '%Deleted%' then
    raise exception 'FAIL: today_screen shows a soft-deleted bride';
  end if;
  raise notice 'PASS: today_screen under tenant F''s JWT returns nothing belonging to tenant G';
end $$;

-- ---------- access_log: one row per bride in the document, same request ----------
do $$
declare n int; got text;
begin
  select count(*), string_agg(bride_id::text, ',' order by bride_id) into n, got
  from access_log where request_id = '35500000-0000-4000-8000-000000000510';
  -- F1 (courses, sessions, payments), F2 (courses, sessions), F3 (payments),
  -- F4 (courses), F8 (other_currency_payment_count only). Not F5 (nothing
  -- about her is in the document), not F6 (soft-deleted).
  if got is distinct from '35100000-0000-4000-8000-0000000000f1,35100000-0000-4000-8000-0000000000f2,'
                          '35100000-0000-4000-8000-0000000000f3,35100000-0000-4000-8000-0000000000f4,'
                          '35100000-0000-4000-8000-0000000000f8' then
    raise exception 'FAIL: access_log fan-out is [%] (% rows), expected F1..F4 and F8 once each', got, n;
  end if;
  select count(*) into n from access_log
  where request_id = '35500000-0000-4000-8000-000000000510'
    and not (tenant_id = auth.uid() and actor_kind = 'instructor' and actor_id = auth.uid()
             and action = 'read' and resource = 'today_screen');
  if n <> 0 then raise exception 'FAIL: % access_log rows are mis-attributed', n; end if;
  raise notice 'PASS: access_log gets exactly one row per bride in the document, attributed to the instructor';
end $$;

-- ---------- p_today is honoured, not decorative ----------
do $$
declare doc jsonb; got text;
begin
  doc := today_screen(date '2030-05-09', '35500000-0000-4000-8000-000000000509');
  -- F1's cancellation (Israeli 05-02) is exactly 7 days old on 05-09: not stale
  select e ->> 'stale_cancellations' into got from jsonb_array_elements(doc -> 'courses') e
  where e ->> 'course_id' = '35200000-0000-4000-8000-0000000000f1';
  if got is distinct from '0' then
    raise exception 'FAIL: stale_cancellations on 2030-05-09 is %, expected 0 (p_today ignored?)', got;
  end if;
  -- no session falls on Israeli 05-09 (F2's 21:30Z is already 05-10 in Israel)
  if jsonb_array_length(doc -> 'sessions_today') <> 0 then
    raise exception 'FAIL: sessions_today on 2030-05-09 is %, expected none', doc -> 'sessions_today';
  end if;

  -- the post-dated cheque counts once its date has passed: F1 then owes 1500
  doc := today_screen(date '2030-05-20', '35500000-0000-4000-8000-000000000520');
  if doc #>> '{payments,outstanding_total}' <> '2900.00' then
    raise exception 'FAIL: outstanding on 2030-05-20 is %, expected 2900.00', doc #>> '{payments,outstanding_total}';
  end if;
  raise notice 'PASS: p_today drives stale cancellations, the Israeli day of sessions and which payments count';
end $$;

-- ---------- refusals ----------
do $$
declare n int;
begin
  begin
    perform today_screen(null, '35500000-0000-4000-8000-0000000000e1');
    raise exception 'FAIL: today_screen accepted a null p_today';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform today_screen(date '2030-05-10', '  ');
    raise exception 'FAIL: today_screen accepted a blank request id';
  exception when sqlstate '22023' then null;
  end;

  -- request_id is written into access_log verbatim: it must be an identifier,
  -- never a carrier for content (security review of #35)
  begin
    perform today_screen(date '2030-05-10', 'Gviria Other is pregnant, see notes');
    raise exception 'FAIL: today_screen accepted free text as a request id';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform today_screen(date '2030-05-10', 'req-35-f-0510');
    raise exception 'FAIL: today_screen accepted a non-uuid request id';
  exception when sqlstate '22023' then null;
  end;
  begin
    -- a uuid with content smuggled after it
    perform today_screen(date '2030-05-10', '35500000-0000-4000-8000-000000000510 pregnant');
    raise exception 'FAIL: today_screen accepted a uuid with trailing text';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform today_screen(date '2030-05-10', E'35500000-0000-4000-8000-000000000510\npregnant');
    raise exception 'FAIL: today_screen accepted a uuid followed by a newline and text';
  exception when sqlstate '22023' then null;
  end;

  -- an impersonated support session must not be logged as the instructor
  perform set_config('request.jwt.claims',
    '{"sub":"35000000-0000-4000-8000-0000000000f0","impersonated_by":"5e000000-0000-4000-8000-000000000001"}', true);
  begin
    perform today_screen(date '2030-05-10', '35500000-0000-4000-8000-0000000000e2');
    raise exception 'FAIL: today_screen ran under an impersonated session';
  exception when sqlstate '42501' then null;
  end;

  perform set_config('request.jwt.claims', '{}', true);
  begin
    perform today_screen(date '2030-05-10', '35500000-0000-4000-8000-0000000000e3');
    raise exception 'FAIL: today_screen ran without an authenticated caller';
  exception when sqlstate '28000' then null;
  end;
end $$;

-- ---------- tenant G sees only its own; tenant H (no brides) logs nothing ----------
set request.jwt.claims = '{"sub":"35000000-0000-4000-8000-0000000000a0"}';
do $$
declare doc jsonb; n int;
begin
  doc := today_screen(date '2030-05-10', '35500000-0000-4000-8000-00000000A510');
  if doc::text like '%35000000-0000-4000-8000-0000000000f0%' or doc::text like '%Avigail%' then
    raise exception 'FAIL: tenant G''s today_screen contains tenant F data';
  end if;
  if jsonb_array_length(doc -> 'courses') <> 1 or jsonb_array_length(doc -> 'sessions_today') <> 1
     or doc #>> '{payments,outstanding_total}' <> '3750.00' then
    raise exception 'FAIL: tenant G document is wrong: %', doc;
  end if;
  select count(*) into n from access_log where request_id like '35500000-%';
  if n <> 1 then
    raise exception 'FAIL: tenant G sees % of the #35 access_log rows, expected only its own 1', n;
  end if;
  -- an upper-case uuid is accepted and stored in canonical lower case
  select count(*) into n from access_log where request_id = '35500000-0000-4000-8000-00000000a510';
  if n <> 1 then
    raise exception 'FAIL: request id was not stored lower-cased';
  end if;
end $$;

set request.jwt.claims = '{"sub":"35000000-0000-4000-8000-0000000000b0"}';
do $$
declare doc jsonb; n int;
begin
  doc := today_screen(date '2030-05-10', '35500000-0000-4000-8000-00000000b510');
  if doc -> 'courses' <> '[]'::jsonb or doc -> 'sessions_today' <> '[]'::jsonb
     or doc #>> '{payments,outstanding_total}' <> '0.00'
     or (doc #>> '{payments,open_course_count}')::int <> 0 then
    raise exception 'FAIL: empty tenant document is %, expected empty arrays and 0.00', doc;
  end if;
  select count(*) into n from access_log where request_id = '35500000-0000-4000-8000-00000000b510';
  if n <> 0 then raise exception 'FAIL: an empty Today wrote % access_log rows; nothing was disclosed', n; end if;
  raise notice 'PASS: tenant G sees only its own Today; an empty Today is well-formed and logs nothing';
end $$;

-- ---------- counted as superuser: the refusals logged nothing, G1 never logged under F ----------
reset role;
reset request.jwt.claims;
do $$
declare n int;
begin
  select count(*) into n from access_log
  where request_id in ('35500000-0000-4000-8000-0000000000e1', '  ', '35500000-0000-4000-8000-0000000000e2', '35500000-0000-4000-8000-0000000000e3',
                       'Gviria Other is pregnant, see notes', 'req-35-f-0510')
     or request_id like '%pregnant%'
     or (resource = 'today_screen'
         and request_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  if n <> 0 then raise exception 'FAIL: a refused today_screen call wrote % access_log rows', n; end if;
  select count(*) into n from access_log
  where request_id like '35500000-%' and bride_id = '35100000-0000-4000-8000-0000000000a1'
    and tenant_id <> '35000000-0000-4000-8000-0000000000a0';
  if n <> 0 then raise exception 'FAIL: tenant G''s bride was logged under another tenant'; end if;
  raise notice 'PASS: refused calls write nothing; every fan-out row belongs to its caller''s tenant';
end $$;

drop table today35;
reset timezone;
-- =============================================================
-- END #35
-- =============================================================

-- =============================================================
-- BEGIN #31 / #34 — platform default grants; session_record's private columns
-- Requires migrations 0005_revoke_platform_default_grants.sql and
-- 0006_session_record_audited_reader.sql, and the default-privilege
-- emulation at the end of schema.bootstrap.sql (without it the #31
-- assertions would pass vacuously).
-- =============================================================
-- Literal ids, as in the #36 section (psql does not interpolate :vars in DO):
--   tenant A  a0000000-0000-4000-8000-000000000001   session a3...0001 (has a record)
--   tenant B  b0000000-0000-4000-8000-000000000002   session b3...0001 (has a record)
--   support engineer (impersonating A)  e0000000-0000-4000-8000-0000000000e1
--   request ids 11111111-0000-4000-8000-00000000000N

-- ---------- #31: anon holds nothing in `public` ----------
do $$
declare rel text; r record;
begin
  -- The bride-data relations, named, so the acceptance criterion is literal...
  foreach rel in array array[
    'instructor','curriculum','curriculum_topic','bride','course','session',
    'session_record','material','payment','message_template','message_log',
    'blackout_date','access_log','portal_session_view','v_course_risk']
  loop
    if to_regclass('public.' || rel) is null then
      raise exception 'FAIL: expected relation public.% is missing', rel;
    end if;
    if has_table_privilege('anon', 'public.' || rel,
         'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       or has_any_column_privilege('anon', 'public.' || rel, 'SELECT,INSERT,UPDATE,REFERENCES') then
      raise exception 'FAIL: anon holds a privilege on bride-data relation %', rel;
    end if;
  end loop;

  -- ...and every relation, sequence and function in `public`, so an object a
  -- later migration adds without following 0005's rule fails here too.
  for r in
    select c.oid::regclass as obj, c.relkind
    from pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.relkind in ('r','p','v','m','f','S')
      and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass
                      and d.objid = c.oid and d.deptype = 'e')
  loop
    if r.relkind = 'S' then
      if has_sequence_privilege('anon', r.obj, 'USAGE,SELECT,UPDATE') then
        raise exception 'FAIL: anon holds a privilege on sequence %', r.obj;
      end if;
      if has_sequence_privilege('authenticated', r.obj, 'USAGE,SELECT,UPDATE') then
        raise exception 'FAIL: authenticated holds a privilege on sequence %', r.obj;
      end if;
    else
      if has_table_privilege('anon', r.obj, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         or has_any_column_privilege('anon', r.obj, 'SELECT,INSERT,UPDATE,REFERENCES') then
        raise exception 'FAIL: anon holds a privilege on %', r.obj;
      end if;
      -- TRUNCATE would erase access_log past its missing DELETE policy (RLS
      -- does not govern TRUNCATE); REFERENCES/TRIGGER are never needed.
      if has_table_privilege('authenticated', r.obj, 'TRUNCATE,REFERENCES,TRIGGER') then
        raise exception 'FAIL: authenticated holds TRUNCATE/REFERENCES/TRIGGER on %', r.obj;
      end if;
      if r.relkind in ('v','m')
         and has_table_privilege('authenticated', r.obj, 'INSERT,UPDATE,DELETE') then
        raise exception 'FAIL: authenticated can write through view %', r.obj;
      end if;
    end if;
  end loop;

  -- has_function_privilege('anon', ...) includes what anon inherits from
  -- PUBLIC, which is how a function created with default ACLs leaks.
  for r in
    select p.oid::regprocedure as fn
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prokind in ('f','p')
      and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass
                      and d.objid = p.oid and d.deptype = 'e')
  loop
    if has_function_privilege('anon', r.fn, 'EXECUTE') then
      raise exception 'FAIL: anon (directly or via PUBLIC) can execute %', r.fn;
    end if;
  end loop;

  raise notice 'PASS: anon holds no privilege on any relation, sequence or function in public; authenticated holds no TRUNCATE/REFERENCES/TRIGGER, no view writes, no sequences';
end $$;

-- ---------- #31: objects created later are closed by default ----------
-- Behavioural, not catalogue-reading: create one of each as the migration
-- role, inspect what the defaults gave them, and roll back. The migration
-- role is whoever owns the schema's tables — the superuser in the default
-- run, pinkas_migrator under SCHEMA_TEST_AS_MIGRATOR=1 — because default
-- privileges belong to the role that creates the object.
begin;
select format('set local role %I', relowner::regrole)
from pg_class where oid = 'public.bride'::regclass
\gexec
create table public.probe31 (id int primary key);
create sequence public.probe31_seq;
create function public.probe31_fn() returns int language sql as 'select 1';
do $$
begin
  if has_table_privilege('anon', 'public.probe31', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
     or has_table_privilege('authenticated', 'public.probe31', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
    raise exception 'FAIL: a new table defaults to privileges for anon or authenticated';
  end if;
  if has_sequence_privilege('anon', 'public.probe31_seq', 'USAGE,SELECT,UPDATE')
     or has_sequence_privilege('authenticated', 'public.probe31_seq', 'USAGE,SELECT,UPDATE') then
    raise exception 'FAIL: a new sequence defaults to privileges for anon or authenticated';
  end if;
  if has_function_privilege('anon', 'public.probe31_fn()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.probe31_fn()', 'EXECUTE') then
    raise exception 'FAIL: a new function defaults to EXECUTE for anon/authenticated/PUBLIC';
  end if;
  -- The recorded service_role decision: its platform defaults are kept. This
  -- also proves the bootstrap's platform emulation is active, without which
  -- every assertion above would be vacuous.
  if not has_table_privilege('service_role', 'public.probe31', 'SELECT')
     or not has_function_privilege('service_role', 'public.probe31_fn()', 'EXECUTE') then
    raise exception 'FAIL: service_role default privileges changed (or the bootstrap no longer emulates the platform) - 0005 records keeping them';
  end if;
  raise notice 'PASS: new tables, sequences and functions grant nothing to anon or authenticated; service_role defaults kept as recorded';
end $$;
rollback;

-- ---------- #31: service_role's table privileges are stated, not ambient ----------
do $$
declare r record;
begin
  for r in
    select c.oid::regclass as obj
    from pg_class c
    where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','v')
      and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass
                      and d.objid = c.oid and d.deptype = 'e')
      and c.relname <> 'session_record'   -- narrowed by 0006, asserted below
  loop
    if not has_table_privilege('service_role', r.obj, 'SELECT') then
      raise exception 'FAIL: service_role lost SELECT on % (0005 records keeping it)', r.obj;
    end if;
  end loop;
  raise notice 'PASS: service_role keeps SELECT on every public relation except session_record';
end $$;

-- ---------- #31: service_role cannot erase or rewrite the audit trail ----------
-- It holds BYPASSRLS, so privileges are the only thing between a service
-- key and access_log. Append and read; nothing else.
do $$
declare p text;
begin
  foreach p in array array['UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] loop
    if has_table_privilege('service_role', 'public.access_log', p) then
      raise exception 'FAIL: service_role holds % on access_log', p;
    end if;
  end loop;
  if not has_table_privilege('service_role', 'public.access_log', 'INSERT')
     or not has_table_privilege('service_role', 'public.access_log', 'SELECT') then
    raise exception 'FAIL: service_role lost INSERT/SELECT on access_log';
  end if;
end $$;
set role service_role;
do $$
begin
  begin
    delete from access_log;
    raise exception 'FAIL: service_role deleted from access_log';
  exception when insufficient_privilege then null;
  end;
  begin
    update access_log set action = 'rewritten';
    raise exception 'FAIL: service_role rewrote access_log';
  exception when insufficient_privilege then null;
  end;
  begin
    truncate access_log;
    raise exception 'FAIL: service_role truncated access_log';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS: service_role may append to and read access_log, never update, delete or truncate it';
end $$;
reset role;

-- ---------- #34: the shape that makes the reader safe ----------
do $$
declare f pg_proc%rowtype; owner pg_roles%rowtype; col text; n int;
begin
  -- the owner role
  select * into owner from pg_roles where rolname = 'session_record_reader';
  if not found then raise exception 'FAIL: role session_record_reader is missing'; end if;
  if owner.rolbypassrls then raise exception 'FAIL: session_record_reader has BYPASSRLS'; end if;
  if owner.rolsuper     then raise exception 'FAIL: session_record_reader is a superuser'; end if;
  if owner.rolcanlogin  then raise exception 'FAIL: session_record_reader can log in'; end if;
  if not pg_has_role('session_record_reader', 'authenticated', 'USAGE') then
    raise exception 'FAIL: session_record_reader does not inherit authenticated - the tenant policies would not apply to it';
  end if;
  if pg_has_role('authenticated', 'session_record_reader', 'MEMBER')
     or pg_has_role('anon', 'session_record_reader', 'MEMBER')
     or pg_has_role('service_role', 'session_record_reader', 'MEMBER') then
    raise exception 'FAIL: an API role can SET ROLE to session_record_reader';
  end if;
  -- RLS does not apply to a table's owner: owning any table would let the
  -- reader see every tenant's rows of it.
  select count(*) into n from pg_class where relowner = owner.oid;
  if n <> 0 then raise exception 'FAIL: session_record_reader owns % relation(s)', n; end if;
  -- CREATE on public is lent for the ALTER ... OWNER hand-over only.
  if has_schema_privilege('session_record_reader', 'public', 'CREATE') then
    raise exception 'FAIL: session_record_reader kept CREATE on schema public after the hand-over';
  end if;
  select count(*) into n from pg_proc where proowner = owner.oid;
  if n <> 1 then raise exception 'FAIL: session_record_reader owns % functions, expected only the reader', n; end if;

  -- the reader
  select * into f from pg_proc
  where oid = to_regprocedure('public.read_session_records(uuid[],uuid)');
  if f.oid is null then raise exception 'FAIL: read_session_records(uuid[],uuid) is missing'; end if;
  if not f.prosecdef then raise exception 'FAIL: read_session_records is not SECURITY DEFINER'; end if;
  if f.proowner <> owner.oid then
    raise exception 'FAIL: read_session_records is owned by %, not session_record_reader',
      f.proowner::regrole;
  end if;
  if (select rolbypassrls or rolsuper from pg_roles where oid = f.proowner) then
    raise exception 'FAIL: read_session_records owner bypasses RLS';
  end if;
  if f.proconfig is null or not ('search_path=""' = any (f.proconfig)) then
    raise exception 'FAIL: read_session_records does not set search_path = '''' (got %)', f.proconfig;
  end if;
  if f.provolatile <> 'v' then raise exception 'FAIL: read_session_records is not VOLATILE - it writes'; end if;
  if not has_function_privilege('authenticated', f.oid, 'EXECUTE') then
    raise exception 'FAIL: authenticated cannot execute read_session_records';
  end if;
  if has_function_privilege('anon', f.oid, 'EXECUTE')
     or has_function_privilege('service_role', f.oid, 'EXECUTE') then
    raise exception 'FAIL: anon or service_role can execute read_session_records';
  end if;

  -- the writer: invoker rights, pinned path, same callers
  select * into f from pg_proc
  where oid = to_regprocedure('public.upsert_session_record(uuid,uuid[],text,text)');
  if f.oid is null then raise exception 'FAIL: upsert_session_record is missing'; end if;
  if f.prosecdef then raise exception 'FAIL: upsert_session_record is SECURITY DEFINER'; end if;
  if f.proconfig is null or not ('search_path=""' = any (f.proconfig)) then
    raise exception 'FAIL: upsert_session_record does not set search_path = ''''';
  end if;
  if not has_function_privilege('authenticated', f.oid, 'EXECUTE')
     or has_function_privilege('anon', f.oid, 'EXECUTE')
     or has_function_privilege('service_role', f.oid, 'EXECUTE') then
    raise exception 'FAIL: upsert_session_record is executable by the wrong roles';
  end if;

  -- column privileges: the three private names are readable by the reader
  -- role and by nobody else; the five the write path needs stay readable.
  if has_table_privilege('authenticated', 'public.session_record', 'SELECT')
     or has_table_privilege('service_role', 'public.session_record', 'SELECT') then
    raise exception 'FAIL: a table-level SELECT on session_record survives';
  end if;
  foreach col in array array['private_note','needs_review_note','covered_topic_ids'] loop
    if has_column_privilege('authenticated', 'public.session_record', col, 'SELECT') then
      raise exception 'FAIL: authenticated can SELECT session_record.%', col;
    end if;
    if has_column_privilege('service_role', 'public.session_record', col, 'SELECT') then
      raise exception 'FAIL: service_role can SELECT session_record.%', col;
    end if;
    if has_column_privilege('anon', 'public.session_record', col, 'SELECT') then
      raise exception 'FAIL: anon can SELECT session_record.%', col;
    end if;
    if not has_column_privilege('session_record_reader', 'public.session_record', col, 'SELECT') then
      raise exception 'FAIL: session_record_reader cannot SELECT session_record.%', col;
    end if;
  end loop;
  foreach col in array array['session_id','tenant_id','created_at','updated_at','deleted_at'] loop
    if not has_column_privilege('authenticated', 'public.session_record', col, 'SELECT') then
      raise exception 'FAIL: authenticated lost SELECT on session_record.% (the write path needs it)', col;
    end if;
  end loop;
  if not has_table_privilege('authenticated', 'public.session_record', 'INSERT')
     or not has_table_privilege('authenticated', 'public.session_record', 'UPDATE') then
    raise exception 'FAIL: authenticated lost INSERT/UPDATE on session_record';
  end if;

  -- §5.2 extended to routines: the three names may leave the database as
  -- output columns of exactly one function, and only the reader and the
  -- writer may mention them at all. A view or function that surfaces a note
  -- any other way fails here, wherever it is introduced.
  select count(*) into n
  from pg_proc p
  cross join lateral unnest(p.proargnames, p.proargmodes) as a(name, mode)
  where p.pronamespace = 'public'::regnamespace
    and a.mode in ('o','t','b')
    and a.name in ('private_note','needs_review_note','covered_topic_ids')
    and p.oid <> to_regprocedure('public.read_session_records(uuid[],uuid)');
  if n <> 0 then
    raise exception 'FAIL: % private output column(s) on a function other than read_session_records', n;
  end if;

  select count(*) into n
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.prosrc ~ '(private_note|needs_review_note|covered_topic_ids)'
    and p.oid not in (to_regprocedure('public.read_session_records(uuid[],uuid)'),
                      to_regprocedure('public.upsert_session_record(uuid,uuid[],text,text)'));
  if n <> 0 then
    raise exception 'FAIL: % function(s) besides the reader/writer reference session_record''s private columns', n;
  end if;

  select count(*) into n
  from pg_views
  where schemaname = 'public'
    and definition ~ '(private_note|needs_review_note|covered_topic_ids)';
  if n <> 0 then
    raise exception 'FAIL: % view(s) reference session_record''s private columns', n;
  end if;

  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.access_log'::regclass
                   and conname = 'access_log_instructor_actor_ck' and contype = 'c') then
    raise exception 'FAIL: access_log_instructor_actor_ck is missing';
  end if;

  raise notice 'PASS: reader is SECURITY DEFINER owned by a NOLOGIN NOBYPASSRLS role, search_path pinned; private columns readable only through it';
end $$;

-- ---------- #34: RLS applies to the reader's role itself ----------
-- Independent of the function: if the role ever stopped matching the tenant
-- policies (membership dropped, BYPASSRLS granted) this shows it directly.
set role session_record_reader;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
do $$
declare n int;
begin
  select count(*) into n from session_record where private_note like 'B %';
  if n <> 0 then raise exception 'FAIL: session_record_reader sees tenant B notes'; end if;
  select count(*) into n from session_record where private_note = 'A private note';
  if n <> 1 then raise exception 'FAIL: session_record_reader does not see tenant A''s own note'; end if;
  raise notice 'PASS: tenant RLS applies to session_record_reader itself';
end $$;
reset role;

-- ---------- #34: reads through the reader, as tenant A ----------
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
do $$
declare n int; note text;
begin
  -- the direct door is shut...
  begin
    perform private_note from session_record;
    raise exception 'FAIL: authenticated read session_record.private_note directly';
  exception when insufficient_privilege then null;
  end;
  begin
    perform needs_review_note from session_record;
    raise exception 'FAIL: authenticated read session_record.needs_review_note directly';
  exception when insufficient_privilege then null;
  end;
  begin
    perform covered_topic_ids from session_record;
    raise exception 'FAIL: authenticated read session_record.covered_topic_ids directly';
  exception when insufficient_privilege then null;
  end;
  begin
    perform * from session_record;
    raise exception 'FAIL: select * on session_record succeeded';
  exception when insufficient_privilege then null;
  end;
  -- ...but the non-private columns still are
  select count(*) into n from session_record where session_id = 'a3000000-0000-4000-8000-000000000001';
  if n <> 1 then raise exception 'FAIL: session_id is no longer readable by its tenant'; end if;

  -- tenant A asking for A's and B's session gets A's only
  select count(*), max(x.private_note) into n, note
  from public.read_session_records(
    array['a3000000-0000-4000-8000-000000000001',
          'b3000000-0000-4000-8000-000000000001']::uuid[],
    '11111111-0000-4000-8000-000000000001') x;
  if n <> 1 or note is distinct from 'A private note' then
    raise exception 'FAIL: reader returned % row(s) / note %, expected tenant A''s one', n, note;
  end if;

  -- THE assertion: tenant B's record, asked for by primary key, is zero rows.
  -- Without it this change would be a hole with a log.
  select count(*) into n
  from public.read_session_records(
    array['b3000000-0000-4000-8000-000000000001']::uuid[],
    '11111111-0000-4000-8000-000000000002');
  if n <> 0 then
    raise exception 'FAIL: the reader returned % tenant B row(s) to tenant A', n;
  end if;

  select count(*) into n from public.read_session_records('{}'::uuid[], null);
  if n <> 0 then raise exception 'FAIL: reader returned rows for an empty id list'; end if;
  select count(*) into n from public.read_session_records(null, null);
  if n <> 0 then raise exception 'FAIL: reader returned rows for a null id list'; end if;

  raise notice 'PASS: private columns not directly readable; the reader returns tenant A''s record and zero rows for tenant B';
end $$;

-- support, impersonating tenant A (SDD §16.2): logged as support, by the engineer
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","impersonated_by":"e0000000-0000-4000-8000-0000000000e1"}';
do $$
declare n int;
begin
  select count(*) into n from public.read_session_records(
    array['a3000000-0000-4000-8000-000000000001']::uuid[],
    '11111111-0000-4000-8000-000000000003');
  if n <> 1 then raise exception 'FAIL: impersonated read returned % rows, expected 1', n; end if;
end $$;

-- an impersonation claim that is not a uuid is refused, not misattributed
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","impersonated_by":"somebody"}';
do $$
begin
  perform * from public.read_session_records(
    array['a3000000-0000-4000-8000-000000000001']::uuid[],
    '11111111-0000-4000-8000-000000000004');
  raise exception 'FAIL: reader accepted a non-uuid impersonated_by claim';
exception when sqlstate '28000' then null;
end $$;

-- no JWT subject: refused
set request.jwt.claims = '{}';
do $$
begin
  perform * from public.read_session_records(
    array['a3000000-0000-4000-8000-000000000001']::uuid[], null);
  raise exception 'FAIL: reader ran without an authenticated caller';
exception when sqlstate '28000' then null;
end $$;
reset role;

-- anon and service_role cannot call the reader or read the columns at all
set role anon;
do $$
begin
  perform * from public.read_session_records(array[]::uuid[], null);
  raise exception 'FAIL: anon executed read_session_records';
exception when insufficient_privilege then null;
end $$;
reset role;
set role service_role;
do $$
begin
  begin
    perform * from public.read_session_records(array[]::uuid[], null);
    raise exception 'FAIL: service_role executed read_session_records';
  exception when insufficient_privilege then null;
  end;
  begin
    perform private_note from session_record;
    raise exception 'FAIL: service_role read session_record.private_note directly (an unlogged support read)';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS: anon and service_role can neither call the reader nor read the private columns';
end $$;
reset role;

-- ---------- #34: every disclosure is logged; nothing else is ----------
do $$
declare r record; n int;
begin
  select count(*) into n from access_log where request_id = '11111111-0000-4000-8000-000000000001';
  if n <> 1 then raise exception 'FAIL: reader wrote % log rows for one disclosed bride, expected 1', n; end if;
  select * into r from access_log where request_id = '11111111-0000-4000-8000-000000000001';
  if r.tenant_id <> 'a0000000-0000-4000-8000-000000000001'
     or r.actor_kind <> 'instructor'
     or r.actor_id is distinct from 'a0000000-0000-4000-8000-000000000001'
     or r.bride_id is distinct from 'a1000000-0000-4000-8000-000000000001'
     or r.action <> 'read' or r.resource <> 'session_record' then
    raise exception 'FAIL: reader log row is wrong: %', row_to_json(r);
  end if;

  -- nothing disclosed, nothing logged - and never a row naming tenant B
  select count(*) into n from access_log
   where request_id in ('11111111-0000-4000-8000-000000000002',
                        '11111111-0000-4000-8000-000000000004');
  if n <> 0 then raise exception 'FAIL: % log rows for reads that disclosed nothing', n; end if;
  select count(*) into n from access_log where tenant_id = 'b0000000-0000-4000-8000-000000000002';
  if n <> 0 then raise exception 'FAIL: tenant A''s reads wrote % log rows under tenant B', n; end if;

  select * into r from access_log where request_id = '11111111-0000-4000-8000-000000000003';
  if r.actor_kind is distinct from 'support'
     or r.actor_id is distinct from 'e0000000-0000-4000-8000-0000000000e1'
     or r.tenant_id <> 'a0000000-0000-4000-8000-000000000001' then
    raise exception 'FAIL: impersonated read not logged as support by the engineer: %', row_to_json(r);
  end if;

  raise notice 'PASS: one access_log row per disclosed bride, attributed from the JWT; none for empty or refused reads';
end $$;

-- The read and its log row cannot come apart: if the log insert fails, the
-- caller receives nothing. Forced with a trigger that rejects the insert.
create function pg_temp.reject_log34() returns trigger language plpgsql as
  $$ begin raise exception 'log rejected' using errcode = 'P0001'; end $$;
create trigger reject_log34 before insert on access_log
  for each row execute function pg_temp.reject_log34();
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
do $$
declare n int := -1;
begin
  begin
    select count(*) into n from public.read_session_records(
      array['a3000000-0000-4000-8000-000000000001']::uuid[],
      '11111111-0000-4000-8000-000000000005');
    raise exception 'FAIL: reader returned % row(s) although its log insert failed', n;
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'log rejected' then raise; end if;
  end;
  raise notice 'PASS: a failed log insert fails the read with it';
end $$;
reset role;
drop trigger reject_log34 on access_log;

-- ---------- #34: the write path works under the column revoke ----------
-- Two fresh tenant-A sessions without records, seeded as superuser.
insert into session (id, tenant_id, course_id, order_index, scheduled_at, status) values
  ('a3000000-0000-4000-8000-0000000000aa', 'a0000000-0000-4000-8000-000000000001',
   'a2000000-0000-4000-8000-000000000001', 2, now() - interval '1 day', 'done'),
  ('a3000000-0000-4000-8000-0000000000ab', 'a0000000-0000-4000-8000-000000000001',
   'a2000000-0000-4000-8000-000000000001', 3, now() - interval '1 day', 'done');

set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
do $$
declare r record; n int;
begin
  -- insert branch
  select * into r from public.upsert_session_record(
    'a3000000-0000-4000-8000-0000000000aa', array['a2000000-0000-4000-8000-0000000000ff']::uuid[],
    'first note', null);
  if r.session_id is distinct from 'a3000000-0000-4000-8000-0000000000aa' then
    raise exception 'FAIL: upsert (insert branch) returned %', row_to_json(r);
  end if;
  -- update branch, same key
  select * into r from public.upsert_session_record(
    'a3000000-0000-4000-8000-0000000000aa', null, 'second note', 'review this');
  select count(*) into n from session_record
   where session_id = 'a3000000-0000-4000-8000-0000000000aa'
     and tenant_id = 'a0000000-0000-4000-8000-000000000001';
  if n <> 1 then raise exception 'FAIL: upsert did not converge on one row (got %)', n; end if;

  -- plain UPDATE ... WHERE session_id (a PostgREST PATCH) still works
  update session_record set needs_review_note = 'review that'
   where session_id = 'a3000000-0000-4000-8000-0000000000aa';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: plain update of an own record touched % rows', n; end if;

  -- plain INSERT (a PostgREST POST, no upsert) still works
  insert into session_record (session_id, tenant_id, private_note)
  values ('a3000000-0000-4000-8000-0000000000ab', 'a0000000-0000-4000-8000-000000000001', 'posted');

  -- the shape PostgREST's .upsert() generates fails, by design: reading
  -- EXCLUDED.private_note needs the column SELECT that was revoked.
  begin
    insert into session_record (session_id, tenant_id, private_note)
    values ('a3000000-0000-4000-8000-0000000000ab', 'a0000000-0000-4000-8000-000000000001', 'merged')
    on conflict (session_id) do update set private_note = excluded.private_note;
    raise exception 'FAIL: ON CONFLICT ... EXCLUDED.private_note succeeded - the column revoke has regressed';
  exception when insufficient_privilege then null;
  end;

  -- another tenant's session cannot take a record
  begin
    perform * from public.upsert_session_record(
      'b3000000-0000-4000-8000-000000000001', null, 'injected', null);
    raise exception 'FAIL: upsert_session_record wrote against tenant B''s session';
  exception when sqlstate 'P0002' then null;
  end;

  -- read back through the reader: the writes landed as written
  select count(*) into n from public.read_session_records(
    array['a3000000-0000-4000-8000-0000000000aa','a3000000-0000-4000-8000-0000000000ab']::uuid[],
    '11111111-0000-4000-8000-000000000006') x
  where (x.session_id = 'a3000000-0000-4000-8000-0000000000aa'
         and x.private_note = 'second note' and x.needs_review_note = 'review that'
         and x.covered_topic_ids = '{}'::uuid[])
     or (x.session_id = 'a3000000-0000-4000-8000-0000000000ab' and x.private_note = 'posted');
  if n <> 2 then raise exception 'FAIL: written records did not read back as written (% of 2)', n; end if;

  raise notice 'PASS: writes work under the column revoke - upsert function (both branches), PATCH, POST; merge-duplicates upsert refused';
end $$;

set request.jwt.claims = '{}';
do $$
begin
  perform * from public.upsert_session_record(
    'a3000000-0000-4000-8000-0000000000aa', null, 'nobody', null);
  raise exception 'FAIL: upsert ran without an authenticated caller';
exception when sqlstate '28000' then null;
end $$;
reset role;

do $$
declare n int;
begin
  select count(*) into n from session_record
   where session_id = 'b3000000-0000-4000-8000-000000000001'
     and (private_note <> 'B private note' or tenant_id <> 'b0000000-0000-4000-8000-000000000002');
  if n <> 0 then raise exception 'FAIL: tenant B''s record was altered by tenant A'; end if;
  select count(*) into n from access_log where request_id = '11111111-0000-4000-8000-000000000006';
  if n <> 1 then raise exception 'FAIL: the read-back of two records for one bride logged % rows, expected 1', n; end if;
end $$;

-- ---------- #34: a record's tenant must be its session's tenant ----------
-- Foreign-key checks ignore RLS; before the composite FK, tenant A could
-- insert a record under her own tenant_id onto tenant B's session id.
insert into session (id, tenant_id, course_id, order_index, scheduled_at, status) values
  ('b3000000-0000-4000-8000-0000000000bb', 'b0000000-0000-4000-8000-000000000002',
   'b2000000-0000-4000-8000-000000000001', 2, now() + interval '9 days', 'planned');
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
do $$
begin
  begin
    insert into session_record (session_id, tenant_id, private_note)
    values ('b3000000-0000-4000-8000-0000000000bb', 'a0000000-0000-4000-8000-000000000001', 'squatting');
    raise exception 'FAIL: tenant A attached a record to tenant B''s session';
  exception when foreign_key_violation then null;
  end;
  raise notice 'PASS: session_record cannot hang off another tenant''s session (composite FK)';
end $$;
reset role;

-- ---------- #34: access_log CHECK, both branches ----------
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
do $$
begin
  -- instructor branch: the actor must be the tenant
  insert into access_log (tenant_id, actor_kind, actor_id, action, resource)
  values (auth.uid(), 'instructor', auth.uid(), 'read', 'bride');
  begin
    insert into access_log (tenant_id, actor_kind, actor_id, action, resource)
    values (auth.uid(), 'instructor', 'e0000000-0000-4000-8000-0000000000e1', 'read', 'bride');
    raise exception 'FAIL: an instructor row attributed to someone other than the tenant was accepted';
  exception when check_violation then null;
  end;
  begin
    insert into access_log (tenant_id, actor_kind, actor_id, action, resource)
    values (auth.uid(), 'instructor', null, 'read', 'bride');
    raise exception 'FAIL: an instructor row attributed to nobody was accepted';
  exception when check_violation then null;
  end;
  -- non-instructor branch: the actor differs from the tenant, by design
  insert into access_log (tenant_id, actor_kind, actor_id, action, resource)
  values (auth.uid(), 'support', 'e0000000-0000-4000-8000-0000000000e1', 'read', 'session_record');

  raise notice 'PASS: access_log CHECK - instructor rows must name the tenant; support rows may name the engineer';
end $$;
reset role;
-- =============================================================
-- END #31 / #34
-- =============================================================

-- =============================================================
-- BEGIN #37 — portal path objects: portal_bride_view, portal_rate_limit
-- Requires migration 0007_portal_bride_view_and_rate_limit.sql.
-- =============================================================
-- Seeded as superuser. Tokens are fake; only their sha256 is stored, exactly
-- as issuance will do it (ADR-0005). Every bride carries the fields the view
-- must NOT expose, so a widened view would have something to leak.
insert into bride (id, tenant_id, first_name, last_name, phone, groom_name, referral_source,
                   wedding_date, status, portal_token_hash, portal_token_issued_at, portal_expires_at) values
  -- A, live link
  ('a1000000-0000-4000-8000-000000000371', 'a0000000-0000-4000-8000-000000000001',
   'Live', 'Levi', '+972500000371', 'Groom A', 'friend', current_date + 40, 'active',
   sha256('tok-37-live'), now() - interval '1 day', now() + interval '54 days'),
  -- A, expired link
  ('a1000000-0000-4000-8000-000000000372', 'a0000000-0000-4000-8000-000000000001',
   'Expired', 'Levi', '+972500000372', 'Groom B', 'friend', current_date - 30, 'completed',
   sha256('tok-37-expired'), now() - interval '90 days', now() - interval '1 second'),
  -- A, soft-deleted bride whose link would otherwise be live
  ('a1000000-0000-4000-8000-000000000373', 'a0000000-0000-4000-8000-000000000001',
   'Deleted', 'Levi', '+972500000373', 'Groom C', 'friend', current_date + 40, 'cancelled',
   sha256('tok-37-deleted'), now() - interval '1 day', now() + interval '54 days'),
  -- A, link with no expiry set (fails closed)
  ('a1000000-0000-4000-8000-000000000374', 'a0000000-0000-4000-8000-000000000001',
   'NoExpiry', 'Levi', '+972500000374', 'Groom D', 'friend', null, 'active',
   sha256('tok-37-noexpiry'), now() - interval '1 day', null),
  -- B, live link — a different tenant
  ('b1000000-0000-4000-8000-000000000371', 'b0000000-0000-4000-8000-000000000002',
   'OtherLive', 'Cohen', '+972500000375', 'Groom E', 'ad', current_date + 40, 'active',
   sha256('tok-37-b-live'), now() - interval '1 day', now() + interval '54 days');
update bride set deleted_at = now() where id = 'a1000000-0000-4000-8000-000000000373';
-- the earlier fixtures (Noa, Rivka, the risk tiers) carry no token at all

-- ---------- shape: the column list is the contract ----------
do $$
declare cols text; n int; opts text[];
begin
  select string_agg(column_name, ',' order by ordinal_position) into cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'portal_bride_view';
  if cols is distinct from 'id,tenant_id,portal_expires_at,portal_token_hash,first_name' then
    raise exception 'FAIL: portal_bride_view surface changed -> %', cols;
  end if;

  select c.reloptions into opts from pg_class c
  where c.oid = 'public.portal_bride_view'::regclass;
  if not coalesce('security_invoker=on' = any(opts) or 'security_invoker=true' = any(opts), false) then
    raise exception 'FAIL: portal_bride_view does not declare security_invoker = on (%)', opts;
  end if;

  -- structurally separate, not filtered: the view reads `bride` and nothing else
  select string_agg(distinct table_name, ',') into cols
  from information_schema.view_table_usage
  where view_schema = 'public' and view_name = 'portal_bride_view';
  if cols is distinct from 'bride' then
    raise exception 'FAIL: portal_bride_view reads from % (expected bride only)', cols;
  end if;

  -- no private field name on either new object
  select count(*) into n
  from information_schema.columns
  where table_schema = 'public'
    and table_name in ('portal_bride_view', 'portal_rate_limit')
    and column_name in ('private_note','needs_review_note','covered_topic_ids');
  if n <> 0 then raise exception 'FAIL: a private field is reachable from a #37 object'; end if;

  -- and the global rule still holds with the new objects in place
  select count(distinct table_name) into n
  from information_schema.columns
  where table_schema = 'public'
    and column_name in ('private_note','needs_review_note','covered_topic_ids');
  if n <> 1 then
    raise exception 'FAIL: private fields are exposed by % relations, expected 1', n;
  end if;

  -- the rate-limit key is a prefix of the HASH; no column may hold token material
  select string_agg(column_name, ',' order by column_name) into cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'portal_rate_limit'
    and column_name like '%token%';
  if cols is distinct from 'token_hash_prefix' then
    raise exception 'FAIL: portal_rate_limit token columns are % (expected token_hash_prefix only)', cols;
  end if;

  -- not a per-bride IP access log: the whole column list is pinned, so a raw
  -- IP, a timestamp beyond the window, or a surrogate id cannot creep back in
  -- — each of those would let the IP row and the prefix row of one request
  -- be joined (security review of #37).
  select string_agg(column_name || ':' || data_type, ',' order by ordinal_position) into cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'portal_rate_limit';
  if cols is distinct from
     'client_ip_hmac:bytea,token_hash_prefix:bytea,window_start:timestamp with time zone,window_seconds:integer,hits:integer' then
    raise exception 'FAIL: portal_rate_limit columns changed -> %', cols;
  end if;
  if exists (select 1 from pg_depend d join pg_class s on s.oid = d.objid
             where s.relkind = 'S' and d.refobjid = 'public.portal_rate_limit'::regclass) then
    raise exception 'FAIL: portal_rate_limit owns a sequence (a surrogate id is a join key)';
  end if;

  if not (select relrowsecurity from pg_class where oid = 'public.portal_rate_limit'::regclass) then
    raise exception 'FAIL: portal_rate_limit does not have RLS enabled';
  end if;

  raise notice 'PASS: portal_bride_view exposes exactly 5 columns, reads only bride; no private field reachable from #37 objects';
end $$;

-- ---------- grants: explicit, minimal, nothing for the browser roles ----------
do $$
declare r text;
begin
  if not has_table_privilege('service_role', 'public.portal_bride_view', 'select') then
    raise exception 'FAIL: service_role cannot select portal_bride_view';
  end if;
  if not has_function_privilege('service_role', 'public.portal_rate_limit_hit(bytea,bytea,integer)', 'execute') then
    raise exception 'FAIL: service_role cannot execute portal_rate_limit_hit';
  end if;

  foreach r in array array['anon', 'authenticated'] loop
    if has_table_privilege(r, 'public.portal_bride_view', 'select') then
      raise exception 'FAIL: % can select portal_bride_view', r;
    end if;
    if has_table_privilege(r, 'public.portal_rate_limit', 'select,insert,update,delete') then
      raise exception 'FAIL: % has privileges on portal_rate_limit', r;
    end if;
    if has_function_privilege(r, 'public.portal_rate_limit_hit(bytea,bytea,integer)', 'execute') then
      raise exception 'FAIL: % can execute portal_rate_limit_hit', r;
    end if;
    if has_function_privilege(r, 'public.portal_rate_limit_prune()', 'execute') then
      raise exception 'FAIL: % can execute portal_rate_limit_prune', r;
    end if;
  end loop;

  if exists (select 1 from pg_class c, aclexplode(c.relacl) a
             where c.oid in ('public.portal_bride_view'::regclass, 'public.portal_rate_limit'::regclass)
               and a.grantee = 0) then
    raise exception 'FAIL: a #37 relation is granted to PUBLIC';
  end if;
  if exists (select 1 from pg_proc p, aclexplode(p.proacl) a
             where p.oid in ('public.portal_rate_limit_hit(bytea,bytea,integer)'::regprocedure,
                             'public.portal_rate_limit_prune()'::regprocedure)
               and a.grantee = 0) then
    raise exception 'FAIL: a #37 function is executable by PUBLIC';
  end if;

  raise notice 'PASS: #37 objects are granted to service_role only';
end $$;

-- ---------- browser roles are refused outright ----------
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
do $$
begin
  begin
    perform 1 from portal_bride_view;
    raise exception 'FAIL: authenticated read portal_bride_view';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from portal_rate_limit;
    raise exception 'FAIL: authenticated read portal_rate_limit';
  exception when insufficient_privilege then null;
  end;
  begin
    perform * from portal_rate_limit_hit(sha256('ip:203.0.113.9'), null, 60);
    raise exception 'FAIL: authenticated executed portal_rate_limit_hit';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set role anon;
do $$
begin
  begin
    perform 1 from portal_bride_view;
    raise exception 'FAIL: anon read portal_bride_view';
  exception when insufficient_privilege then null;
  end;
  begin
    perform * from portal_rate_limit_hit(sha256('ip:203.0.113.9'), null, 60);
    raise exception 'FAIL: anon executed portal_rate_limit_hit';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS: anon and authenticated are refused every #37 object';
end $$;
reset role;

-- ---------- token resolution, as the service role ----------
set role service_role;
set request.jwt.claims = '{}';
do $$
declare r record; n int;
begin
  -- the one lookup lib/data/portal.ts performs: equality on the hash
  select * into r from portal_bride_view where portal_token_hash = sha256('tok-37-live');
  if r.id is distinct from 'a1000000-0000-4000-8000-000000000371'::uuid
     or r.tenant_id is distinct from 'a0000000-0000-4000-8000-000000000001'::uuid
     or r.first_name is distinct from 'Live'
     or r.portal_expires_at is null then
    raise exception 'FAIL: live token did not resolve to its bride (%)', r;
  end if;

  select count(*) into n from portal_bride_view where portal_token_hash = sha256('tok-37-expired');
  if n <> 0 then raise exception 'FAIL: an expired link resolved'; end if;
  select count(*) into n from portal_bride_view where portal_token_hash = sha256('tok-37-deleted');
  if n <> 0 then raise exception 'FAIL: a soft-deleted bride''s link resolved'; end if;
  select count(*) into n from portal_bride_view where portal_token_hash = sha256('tok-37-noexpiry');
  if n <> 0 then raise exception 'FAIL: a link with no expiry resolved'; end if;
  select count(*) into n from portal_bride_view where portal_token_hash = sha256('not-a-token');
  if n <> 0 then raise exception 'FAIL: an unknown token resolved'; end if;

  -- The honest half: this view is NOT isolation. Without the hash predicate the
  -- service role sees every tenant's resolvable brides. This assertion pins
  -- that, so nobody reads the view as a tenant boundary — re-read the 0007
  -- header before changing it.
  select count(*) into n from portal_bride_view;
  if n <> 2 then
    raise exception 'FAIL: unfiltered portal_bride_view returned % rows, expected 2 (A live + B live)', n;
  end if;

  -- The service role and the base tables. schema.bootstrap.sql models
  -- Supabase's default privileges (#31), so service_role holds table-level
  -- SELECT on `bride` here exactly as it does on live Supabase: the portal key
  -- CAN read bride.phone, and RLS does not stop it (BYPASSRLS). 0007's column
  -- grant narrows nothing until a migration revokes that table-level privilege
  -- (#53). This assertion pins the current state, so the migration that lands
  -- the revoke has to change it — and the 0007 header — in the same diff.
  if not has_table_privilege('service_role', 'public.bride', 'SELECT') then
    raise exception 'FAIL: service_role lost table-level SELECT on bride; update this assertion and the 0007 header together (#53)';
  end if;
  -- session_record's private columns are refused to service_role by 0006 and
  -- asserted in the #31 / #34 section; nothing in 0007 touches session_record.

  raise notice 'PASS: portal_bride_view resolves live tokens only; column-narrowed, explicitly not tenant-isolated';
end $$;

-- ---------- rate-limit counter, as the service role ----------
-- Clock-independent by construction: everything below runs in one DO block,
-- i.e. one transaction, and portal_rate_limit_hit() takes its window from
-- now() — the transaction start — so every hit here lands in the same window
-- for each window length, however close to a boundary the suite happens to
-- run. sha256('ip:...') stands in for the HMAC portal.ts computes; the table
-- only needs 32 opaque bytes.
do $$
declare r record; i int;
begin
  for i in 1..3 loop
    select * into r from portal_rate_limit_hit(sha256('ip:203.0.113.7'), '\xdeadbeefdeadbeef'::bytea, 3600);
  end loop;
  if r.ip_hits <> 3 or r.token_hash_prefix_hits <> 3 then
    raise exception 'FAIL: after 3 hits got ip=% prefix=%', r.ip_hits, r.token_hash_prefix_hits;
  end if;
  if r.window_ends_at <= now() or r.window_ends_at > now() + interval '3600 seconds' then
    raise exception 'FAIL: window_ends_at % is not inside the current window', r.window_ends_at;
  end if;

  -- buckets are independent
  select * into r from portal_rate_limit_hit(sha256('ip:203.0.113.7'), '\xcafebabecafebabe'::bytea, 3600);
  if r.ip_hits <> 4 or r.token_hash_prefix_hits <> 1 then
    raise exception 'FAIL: independent buckets got ip=% prefix=%', r.ip_hits, r.token_hash_prefix_hits;
  end if;

  -- a NULL bucket is not counted and writes nothing
  select * into r from portal_rate_limit_hit(null, '\xcafebabecafebabe'::bytea, 3600);
  if r.ip_hits is not null or r.token_hash_prefix_hits <> 2 then
    raise exception 'FAIL: prefix-only hit got ip=% prefix=%', r.ip_hits, r.token_hash_prefix_hits;
  end if;

  -- a different window length is a different counter
  select * into r from portal_rate_limit_hit(sha256('ip:203.0.113.7'), null, 60);
  if r.ip_hits <> 1 then raise exception 'FAIL: 60s window shared the 3600s counter (%)', r.ip_hits; end if;

  begin
    perform * from portal_rate_limit_hit(null, null, 60);
    raise exception 'FAIL: a hit with no bucket key was accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform * from portal_rate_limit_hit(sha256('ip:203.0.113.7'), null, 0);
    raise exception 'FAIL: a zero-length window was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- the prefix is exactly 8 bytes: shorter or longer would split one link's
  -- count across buckets, and a full sha256 is the lookup key, not a bucket
  begin
    perform * from portal_rate_limit_hit(null, '\xdeadbeef'::bytea, 60);
    raise exception 'FAIL: a 4-byte prefix was accepted';
  exception when check_violation then null;
  end;
  begin
    perform * from portal_rate_limit_hit(null, sha256('tok-37-live'), 60);
    raise exception 'FAIL: a 32-byte hash was accepted as a prefix';
  exception when check_violation then null;
  end;
  -- the IP key must be a 32-byte HMAC: a raw IP's text or bytes is refused
  begin
    perform * from portal_rate_limit_hit(convert_to('203.0.113.7', 'UTF8'), null, 60);
    raise exception 'FAIL: a raw IP was accepted as client_ip_hmac';
  exception when check_violation then null;
  end;
  -- and a row cannot key on both at once
  begin
    insert into portal_rate_limit (client_ip_hmac, token_hash_prefix, window_start, window_seconds)
    values (sha256('ip:203.0.113.8'), '\xdeadbeefdeadbeef'::bytea, now(), 60);
    raise exception 'FAIL: a row keyed on both ip and prefix was accepted';
  exception when check_violation then null;
  end;

  raise notice 'PASS: portal_rate_limit_hit counts per IP-HMAC and per hash prefix in fixed windows';
end $$;
reset role;

-- ---------- prune removes ended windows only ----------
-- Clock-independent: the expected count is computed in the same transaction
-- as the prune, against the same now(), so a window that happened to end
-- since the block above simply counts as ended on both sides.
insert into portal_rate_limit (client_ip_hmac, window_start, window_seconds, hits)
values (sha256('ip:198.51.100.1'), now() - interval '2 hours', 3600, 9);
set role service_role;
do $$
declare n int; want int; before int;
begin
  select count(*) filter (where window_start + make_interval(secs => window_seconds) <= now()),
         count(*)
    into want, before
  from portal_rate_limit;
  if want < 1 then raise exception 'FAIL: prune fixture is not an ended window'; end if;

  select portal_rate_limit_prune() into n;
  if n <> want then raise exception 'FAIL: prune deleted % rows, expected %', n, want; end if;

  if exists (select 1 from portal_rate_limit where client_ip_hmac = sha256('ip:198.51.100.1')) then
    raise exception 'FAIL: prune left the ended window behind';
  end if;
  select count(*) into n from portal_rate_limit;
  if n <> before - want then
    raise exception 'FAIL: prune removed live windows (% left, expected %)', n, before - want;
  end if;
  raise notice 'PASS: portal_rate_limit_prune deletes ended windows and keeps current ones';
end $$;
reset role;

-- ---------- concurrency: no lost increments ----------
-- Four real backends, as service_role, each committing 250 separate
-- autocommit calls against the same two counters, interleaved so that every
-- round has four calls in flight at once. dblink lives in a scratch schema
-- that is dropped afterwards, so it never looks like part of the schema.
-- Requires the dblink contrib module (shipped in the postgres:16 image CI
-- uses) and a superuser running the suite, which the harness already is.
--
-- Clock-independent: these are 1000 separate transactions, so a run that
-- straddles a UTC-midnight boundary legitimately splits each bucket across
-- two windows. The assertion is therefore on the total over windows (no
-- increment lost) and on at most two rows per bucket (one per window — the
-- unique index makes a duplicate within a window impossible anyway).
create schema test37;
create extension dblink schema test37;
do $$
declare
  conninfo text := format('dbname=%s user=%s port=%s host=%s',
                          current_database(), current_user, current_setting('port'),
                          split_part(current_setting('unix_socket_directories'), ',', 1));
  q text := 'select ip_hits, token_hash_prefix_hits from public.portal_rate_limit_hit('
         || 'sha256(''ip:192.0.2.37''), ''\x3737373737373737''::bytea, 86400)';
  c int; i int; r record;
begin
  for c in 1..4 loop
    perform test37.dblink_connect('c37_' || c, conninfo);
    perform test37.dblink_exec('c37_' || c, 'set role service_role');
  end loop;
  for i in 1..250 loop
    for c in 1..4 loop
      perform test37.dblink_send_query('c37_' || c, q);
    end loop;
    for c in 1..4 loop
      perform * from test37.dblink_get_result('c37_' || c) as t(a int, b int);
      perform * from test37.dblink_get_result('c37_' || c) as t(a int, b int);  -- terminating empty set
    end loop;
  end loop;
  for c in 1..4 loop
    perform test37.dblink_disconnect('c37_' || c);
  end loop;

  select
    sum(hits)  filter (where client_ip_hmac = sha256('ip:192.0.2.37'))          as ip,
    count(*)   filter (where client_ip_hmac = sha256('ip:192.0.2.37'))          as ip_rows,
    sum(hits)  filter (where token_hash_prefix = '\x3737373737373737'::bytea)   as pref,
    count(*)   filter (where token_hash_prefix = '\x3737373737373737'::bytea)   as pref_rows
  into r from portal_rate_limit where window_seconds = 86400;
  if r.ip is distinct from 1000 or r.pref is distinct from 1000
     or r.ip_rows not between 1 and 2 or r.pref_rows not between 1 and 2 then
    raise exception 'FAIL: concurrent hits: ip=% (% rows) prefix=% (% rows); expected 1000 each in 1-2 windows',
      r.ip, r.ip_rows, r.pref, r.pref_rows;
  end if;
  raise notice 'PASS: 4 backends x 250 concurrent hits counted exactly 1000 per bucket';
end $$;
drop schema test37 cascade;
-- =============================================================
-- END #37
-- =============================================================
