-- =============================================================
-- 0004 — today_screen: the single aggregated query behind the Today screen
-- Issue #35. Relates to SDD §12.1 (plate 01), §18.1 (one query, <2s),
-- §8 (risk), §13 (the access log), §15 (offline), ADR-0002, ADR-0006.
-- Depends on 0003 (course_risk(p_today), jerusalem_date) — without it p_today
-- could not reach the risk aggregate and would be decorative.
--
-- Expand-only: one new function and its grants. Nothing existing changes.
-- =============================================================
--
-- WHY A FUNCTION
--
-- §18.1 wants risk, today's sessions and the payment total in ONE round trip.
-- PostgREST embedding cannot span v_course_risk, a session date filter and a
-- payment aggregate, and a view cannot take p_today or write the access log.
-- So: one function, one SELECT whose CTEs read everything and whose
-- data-modifying CTE writes the access_log fan-out — the log write is part of
-- the read, in the same statement, not adjacent to it (invariant 3). If either
-- half fails, both roll back.
--
-- WHY security invoker
--
-- This is a query shape, not a privilege escalation. RLS applies to every
-- table the body touches (course, bride, session, payment, instructor, and
-- course_risk's own reads), and the access_log insert satisfies
-- `with check (tenant_id = auth.uid())` because tenant_id IS auth.uid().
-- There is no tenant parameter. (Invariant 1.)
--
-- THE AGGREGATE, NOT THE VERDICT (decided in #7's design challenge)
--
-- `courses` carries course_risk's aggregate columns — never risk_level,
-- risk_reason_code or days_to_deadline. lib/data/today.ts hands them to
-- assessRisk() in lib/domain/risk.ts, so the online screen and the offline one
-- (§15, served from cache and necessarily computed by risk.ts) cannot rank the
-- same bride differently. Since 0003 the remaining seam is narrow:
-- stale_cancellations arrives pre-computed (the 7-day threshold is applied in
-- SQL — shipping every session to avoid it would defeat the aggregation), but
-- against p_today, in the same civil-day reading risk.ts uses.
--
-- p_today IS HONOURED THROUGHOUT
--
--   courses        : course_risk(p_today) — stale_cancellations is relative to it
--   sessions_today : sessions whose Asia/Jerusalem civil date is p_today
--   payments       : only payments with paid_at <= p_today count as paid (a
--                    post-dated cheque has not been paid yet)
--
-- p_today is the caller's civil date in Asia/Jerusalem (lib/data/ computes it
-- from the clock and injects it, as the domain does). It is not range-checked:
-- a caller passing another date sees her own data as of that date and nothing
-- more, since RLS — not p_today — decides what is visible.
--
-- ACCESS LOG FAN-OUT
--
-- One access_log row per DISTINCT bride whose data appears anywhere in the
-- document — the risk list, today's sessions, an open balance counted into
-- the payment total, or a foreign-currency payment counted into
-- other_currency_payment_count — all sharing p_request_id. A bride whose rows
-- contribute to any number in the document is logged, even when that number
-- is only a count. A bride in two sections is one row.
--
-- p_REQUEST_ID MUST BE A UUID. access_log.request_id is text and the log must
-- hold identifiers only, never content (SDD §3.11); a free-text parameter
-- written verbatim into it would be a side channel for exactly the content
-- the log must not carry (security review of #35: "<name> is pregnant, see
-- notes" was storable). The parameter stays `text` — so the signature other
-- migrations grant and revoke on is unchanged and a bad value fails with a
-- clear 22023 rather than a cast error — but it must match the canonical
-- 8-4-4-4-12 hex form, and is stored lower-cased. A tenant with nothing to show writes no row: the log records what was
-- disclosed, and nothing was. actor_kind is the literal 'instructor': a support
-- session impersonating the tenant (an `impersonated_by` JWT claim, #7 A′) is
-- refused outright rather than logged as the instructor, which is exactly the
-- misattribution SDD §16.2 forbids. Support reads need their own door.
--
-- RETURNED DOCUMENT (the contract lib/data/today.ts validates; asserted in
-- schema.test.sql — adding or removing a key is a change to that test)
--
-- {
--   "today":    "YYYY-MM-DD",              -- p_today echoed
--   "timezone": "Asia/Jerusalem",
--   "courses": [                          -- every active course; order: target_end_date nulls last, course_id
--     { "course_id":           uuid,
--       "bride_id":            uuid,
--       "bride_first_name":    text,
--       "bride_last_name":     text | null,
--       "sessions_remaining":  integer,
--       "sessions_done":       integer,
--       "last_done_at":        timestamptz (ISO 8601) | null,
--       "last_done_on":        "YYYY-MM-DD" | null,  -- last_done_at as an Israeli civil date
--       "stale_cancellations": integer,               -- relative to p_today
--       "target_end_date":     "YYYY-MM-DD" | null,
--       "wedding_date":        "YYYY-MM-DD" | null }
--   ],
--   "sessions_today": [                   -- planned/done sessions on p_today (Israel); order: scheduled_at, session_id
--     { "session_id":       uuid,
--       "course_id":        uuid,
--       "bride_id":         uuid,
--       "bride_first_name": text,
--       "bride_last_name":  text | null,
--       "bride_phone":      text | null,  -- E.164; the one-tap wa.me reminder (§14) needs it
--       "order_index":      integer,
--       "scheduled_at":     timestamptz (ISO 8601),
--       "duration_minutes": integer,
--       "location":         text | null,
--       "status":           "planned" | "done" }
--   ],
--   "payments": {                         -- "one number, detail behind a tap" (plate 01 note a5)
--     "currency":                     "ILS",     -- instructor.currency
--     "outstanding_total":            "3400.00", -- a decimal STRING: money never travels as a float
--     "open_course_count":            integer,
--     "open_bride_count":             integer,
--     "other_currency_payment_count": integer    -- payments not in `currency`, excluded from the sum
--   }
-- }
--
-- Payment scope: courses that are active or completed, not soft-deleted, of a
-- bride not soft-deleted, with an agreed_price. course.agreed_price carries no
-- currency, so it is read as instructor.currency; a payment in any other
-- currency cannot be netted against it without a rate, so it is excluded from
-- the sum and counted in other_currency_payment_count rather than silently
-- mis-added. Draft and cancelled courses owe nothing on this screen.
--
-- Arrays are always arrays (never null); counts are always numbers.
-- =============================================================

create function public.today_screen(p_today date, p_request_id text)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = public, pg_temp
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_claims text := current_setting('request.jwt.claims', true);
  v_doc    jsonb;
begin
  if v_uid is null then
    raise exception 'today_screen: requires an authenticated caller'
      using errcode = '28000';
  end if;

  -- Fail closed on an impersonated session (#7 A′): this function can only
  -- log as 'instructor', and a support read must never be recorded as one.
  if coalesce(v_claims, '') <> '' and (v_claims::jsonb ? 'impersonated_by') then
    raise exception 'today_screen: refuses impersonated sessions; support reads must be logged as support'
      using errcode = '42501';
  end if;

  if p_today is null then
    raise exception 'today_screen: p_today is required (the caller''s Asia/Jerusalem civil date)'
      using errcode = '22023';
  end if;

  -- request_id is what ties this read's fan-out together in the log; a read
  -- that cannot be correlated is not one the log can explain later. It must be
  -- a uuid and nothing else: the log holds identifiers, never content.
  if p_request_id is null
     or p_request_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'today_screen: p_request_id must be a uuid (8-4-4-4-12 hex)'
      using errcode = '22023';
  end if;

  with
  cur as (
    select coalesce(
      (select i.currency from instructor i where i.id = v_uid), 'ILS')::text as currency
  ),
  risk as (
    select r.course_id, r.bride_id,
           b.first_name, b.last_name,
           r.sessions_remaining, r.sessions_done,
           r.last_done_at, jerusalem_date(r.last_done_at) as last_done_on,
           r.stale_cancellations, r.target_end_date, r.wedding_date
    from course_risk(p_today) r
    join bride b on b.id = r.bride_id
  ),
  todays as (
    select s.id as session_id, s.course_id, c.bride_id,
           b.first_name, b.last_name, b.phone,
           s.order_index, s.scheduled_at, s.duration_minutes, s.location, s.status
    from session s
    join course c on c.id = s.course_id
    join bride  b on b.id = c.bride_id
    where s.deleted_at is null
      and c.deleted_at is null
      and b.deleted_at is null
      and s.status in ('planned', 'done')
      -- the Israeli civil day p_today, as a half-open instant range so the
      -- (tenant_id, scheduled_at) index can serve it
      and s.scheduled_at >= (p_today::timestamp       at time zone 'Asia/Jerusalem')
      and s.scheduled_at <  ((p_today + 1)::timestamp at time zone 'Asia/Jerusalem')
  ),
  owed as (
    select c.id as course_id, c.bride_id, c.agreed_price,
           coalesce(sum(p.amount) filter (where p.currency = cur.currency), 0) as paid,
           count(p.id) filter (where p.currency <> cur.currency)              as other_currency
    from course c
    join bride b on b.id = c.bride_id
    cross join cur
    left join payment p
      on p.course_id = c.id
     and p.deleted_at is null
     and p.paid_at <= p_today
    where c.deleted_at is null
      and b.deleted_at is null
      and c.status in ('active', 'completed')
      and c.agreed_price is not null
    group by c.id, c.bride_id, c.agreed_price
  ),
  open_owed as (
    select * from owed where agreed_price - paid > 0
  ),
  subjects as (
    select bride_id from risk
    union
    select bride_id from todays
    union
    select bride_id from open_owed
    union
    -- feeds other_currency_payment_count, even when the course is fully paid
    select bride_id from owed where other_currency > 0
  ),
  logged as (
    insert into access_log (tenant_id, actor_kind, actor_id, bride_id, action, resource, request_id)
    select v_uid, 'instructor', v_uid, s.bride_id, 'read', 'today_screen', lower(p_request_id)
    from subjects s
  )
  select jsonb_build_object(
    'today',    p_today,
    'timezone', 'Asia/Jerusalem',
    'courses', coalesce((
      select jsonb_agg(jsonb_build_object(
               'course_id',           r.course_id,
               'bride_id',            r.bride_id,
               'bride_first_name',    r.first_name,
               'bride_last_name',     r.last_name,
               'sessions_remaining',  r.sessions_remaining,
               'sessions_done',       r.sessions_done,
               'last_done_at',        r.last_done_at,
               'last_done_on',        r.last_done_on,
               'stale_cancellations', r.stale_cancellations,
               'target_end_date',     r.target_end_date,
               'wedding_date',        r.wedding_date)
             order by r.target_end_date nulls last, r.course_id)
      from risk r), '[]'::jsonb),
    'sessions_today', coalesce((
      select jsonb_agg(jsonb_build_object(
               'session_id',       t.session_id,
               'course_id',        t.course_id,
               'bride_id',         t.bride_id,
               'bride_first_name', t.first_name,
               'bride_last_name',  t.last_name,
               'bride_phone',      t.phone,
               'order_index',      t.order_index,
               'scheduled_at',     t.scheduled_at,
               'duration_minutes', t.duration_minutes,
               'location',         t.location,
               'status',           t.status)
             order by t.scheduled_at, t.session_id)
      from todays t), '[]'::jsonb),
    'payments', (
      select jsonb_build_object(
               'currency',                     cur.currency,
               'outstanding_total',
                 (select coalesce(sum(o.agreed_price - o.paid), 0)::numeric(12,2)::text from open_owed o),
               'open_course_count',
                 (select count(*) from open_owed),
               'open_bride_count',
                 (select count(distinct o.bride_id) from open_owed o),
               'other_currency_payment_count',
                 (select coalesce(sum(w.other_currency), 0)::bigint from owed w))
      from cur)
  )
  into v_doc;

  return v_doc;
end
$fn$;

comment on function public.today_screen(date, text) is
  'The Today screen in one round trip (SDD 12.1, 18.1; issue #35): the risk '
  'AGGREGATE per active course (lib/domain/risk.ts computes the verdict), '
  'today''s sessions and the open-payment total, all as of p_today '
  '(Asia/Jerusalem civil date). Writes one access_log row per bride in the '
  'document, in the same statement; p_request_id must be a uuid (the log holds '
  'identifiers, never content). security invoker - RLS applies. The '
  'returned shape is documented in migration 0004.';

-- Signed-in instructors only. Revoked by name from anon and service_role as
-- well as PUBLIC: Supabase's default privileges grant EXECUTE on new public
-- functions to both (#31), and invariant 5 confines service_role to the
-- portal read path.
revoke execute on function public.today_screen(date, text) from public, anon, service_role;
grant  execute on function public.today_screen(date, text) to authenticated;
