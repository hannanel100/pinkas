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
-- Requires migration 0005_bootstrap_instructor_atomic.sql.
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
