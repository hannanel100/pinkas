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

  select count(*) into n from session_record where private_note like 'B %';
  if n <> 0 then raise exception 'FAIL: tenant A read tenant B private_note'; end if;

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
