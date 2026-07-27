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
