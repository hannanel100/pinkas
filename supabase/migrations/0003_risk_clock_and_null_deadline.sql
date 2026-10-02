-- =============================================================
-- 0003 — v_course_risk: one clock (Asia/Jerusalem), and no tier without a deadline
-- Issues #38 and #42, deliberately in one migration: both rewrite the same
-- `greatest(0, target_end_date - current_date)` expression, and two migrations
-- rewriting one expression a week apart is how the view and lib/domain/risk.ts
-- drift. Relates to SDD §8.1 (tiers), §8.4 (nightly job), §9.4 (timezone).
--
-- Expand-only in shape (docs/runbooks/migrations.md): v_course_risk keeps its
-- exact column list, names, types and order, and its grants. Two functions are
-- added. What changes is the *values* the view computes, which is the point:
-- no deployed code reads the view yet (lib/data/ is still empty), and the
-- nightly job (§8.4) is Phase 2.
-- =============================================================
--
-- #38 — THE CLOCK
--
-- 0001 computed against `current_date` and `now()`, i.e. the *session*
-- timezone. On Supabase that is UTC, while §9.4 says everything is
-- Asia/Jerusalem. For the two to three hours after Israeli midnight the
-- database's `current_date` was still yesterday, so `days_to_deadline` read one
-- day too many — "18 days" shown as "19" — on the one number the product exists
-- to get right.
--
-- Fixed by making the clock a *parameter* rather than an ambient setting:
--
--   * public.jerusalem_date(timestamptz) — the single place an instant becomes
--     an Israeli civil date. Every date the risk computation reads goes through
--     it, so there is no second clock left anywhere in the view.
--   * public.course_risk(p_today date) — the view's body, parameterised. Postgres
--     has no parameterised views; a `language sql`, `security invoker`,
--     set-returning function is the closest thing, and it is inlinable, so the
--     planner sees through it exactly as it would a view.
--   * v_course_risk — now `course_risk(jerusalem_date(now()))`. Same columns,
--     same consumers, correct clock. The nightly job (§8.4) reads this.
--
-- Why a parameter and not `set timezone` on a function or the role: a
-- session-level setting is ambient state that every caller must remember (the
-- pooler, pg_cron, a psql session someone opens at 01:00), and it would leave
-- the today_screen RPC's `p_today` (#35) decorative — the RPC could not make the
-- view use the date it was handed. With the parameter, today_screen calls
-- course_risk(p_today) and the whole document runs on one supplied date.
--
-- WHY THE TIME-BASED TIERS MOVED TO CIVIL DAYS TOO
--
-- `stale_cancellations` (the `high` tier) and the `medium` tier compared
-- instants: `scheduled_at < now() - interval '7 days'`. That is a second clock,
-- and one a `p_today` parameter cannot reach. Both are now civil-day
-- comparisons in Asia/Jerusalem, as §9.4 requires of date arithmetic:
--
--   high   : jerusalem_date(scheduled_at)  < p_today - 7    (">7 days ago")
--   medium : jerusalem_date(last_done_at)  < p_today - 21   (">21 days since")
--   info   : wedding_date                 <= p_today + 30   (unchanged)
--
-- This is a boundary change measured in hours, and it is in the direction of
-- the pure mirror: lib/domain/risk.ts already took exactly these civil-day,
-- strictly-greater readings and documented the instant-based view as the
-- approximation. The mirror's logic needs no change; its header no longer
-- needs to apologise for the difference.
--
-- #42 — A COURSE WITH NO DEADLINE HAS NO `critical` TIER  (decision)
--
-- 0001 ranked an active course with `target_end_date is null` and any planned
-- session `critical` / `wont_finish_in_time`, reporting `days_to_deadline = 0`.
-- The cause is `greatest()`, which in Postgres IGNORES null arguments rather
-- than propagating them (unlike Oracle and MySQL, and unlike almost every other
-- function in the expression):
--
--     greatest(0, null::int)                                  -> 0, not null
--     sessions_remaining > floor(greatest(0, null) / 7.0)     -> true
--
-- Two readings were available; this migration takes the first:
--
--   1. A course with no deadline has no deadline tier.  <- chosen
--   2. An active course must have a deadline (CHECK target_end_date is not null
--      when status = 'active').
--
-- Why (1): "won't finish in time" is a claim about a deadline, and there is no
-- deadline to miss — ranking it critical is the system asserting something it
-- does not know, the same honesty rule as invariant 9. (1) also needs no
-- migration against existing rows and moves no failure into whatever code
-- activates a course; lib/domain/risk.ts already behaves this way, so the view
-- and the mirror now agree, which #42 requires. Reading (2) remains open as a
-- product decision about *activation*: if the product decides a course may
-- not be active without a schedule, that constraint can be added later
-- without touching this expression. The cost of (1), accepted: a deadline-less
-- course is not escalated on deadline grounds. It still ranks on the other
-- four tiers, still appears in the view, and `days_to_deadline` is null —
-- never 0 — so the UI can say "no deadline set" instead of "0 days".
--
-- The null is now handled explicitly with a `case`, and the `critical` branch
-- tests `days_to_deadline is not null` out loud, so nobody has to remember how
-- greatest() treats nulls to read it correctly.
--
-- ROW SELECTION: course_risk also excludes soft-deleted brides
-- (`b.deleted_at is null`). 0001 filtered soft-deleted courses but not their
-- brides, so a deleted bride's active course would have kept ranking — and,
-- once #35 lands, kept her name on the Today screen. risk.ts documents row
-- selection as "active, not deleted"; this makes the view say the same.
-- =============================================================

-- ---------- the clock ----------
-- Not `set search_path`: a SET clause stops a SQL function being inlined, and
-- the body references nothing outside pg_catalog.
create function public.jerusalem_date(p_at timestamptz)
returns date
language sql
stable
parallel safe
as $fn$
  select (p_at at time zone 'Asia/Jerusalem')::date
$fn$;

comment on function public.jerusalem_date(timestamptz) is
  'The Israeli civil date of an instant (SDD 9.4). The one place the risk '
  'computation turns a timestamptz into a date; issue #38.';

-- ---------- the view body, parameterised by the civil date ----------
-- security invoker (the default, stated): RLS on course, bride and session
-- applies to the caller exactly as it did inside the view. Every relation is
-- schema-qualified because, as above, the function is left inlinable rather
-- than given a pinned search_path.
create function public.course_risk(p_today date)
returns table (
  course_id           uuid,
  tenant_id           uuid,
  bride_id            uuid,
  sessions_remaining  bigint,
  sessions_done       bigint,
  last_done_at        timestamptz,
  stale_cancellations bigint,
  target_end_date     date,
  wedding_date        date,
  days_to_deadline    integer,
  risk_level          public.risk_level,
  risk_reason_code    text
)
language sql
stable
security invoker
as $fn$
  with agg as (
    select
      c.id              as course_id,
      c.tenant_id       as tenant_id,
      c.bride_id        as bride_id,
      c.target_end_date as target_end_date,
      b.wedding_date    as wedding_date,
      count(s.id) filter (where s.status = 'planned')      as sessions_remaining,
      count(s.id) filter (where s.status = 'done')         as sessions_done,
      max(s.scheduled_at) filter (where s.status = 'done') as last_done_at,
      -- high tier's operand: cancelled more than 7 *civil days* before p_today
      -- and never rescheduled. A null scheduled_at is never stale (null < x is
      -- not true), matching risk.ts.
      count(s.id) filter (
        where s.status = 'cancelled'
          and public.jerusalem_date(s.scheduled_at) < p_today - 7
          and not exists (
            select 1 from public.session r
            where r.rescheduled_from_session_id = s.id
              and r.deleted_at is null
          )
      ) as stale_cancellations
    from public.course c
    join public.bride b on b.id = c.bride_id
    left join public.session s on s.course_id = c.id and s.deleted_at is null
    where c.deleted_at is null
      and b.deleted_at is null
      and c.status = 'active'
    group by c.id, c.tenant_id, c.bride_id, c.target_end_date, b.wedding_date
  ),
  d as (
    select
      agg.*,
      -- #42: NULL deadline -> NULL days, never 0. Postgres greatest() IGNORES
      -- nulls (greatest(0, null) = 0), so the null must be handled before it
      -- reaches greatest(), not left to propagate through it.
      case
        when agg.target_end_date is null then null
        else greatest(0, agg.target_end_date - p_today)
      end as days_to_deadline,
      public.jerusalem_date(agg.last_done_at) as last_done_on
    from agg
  )
  -- §8.1: evaluated in order, first match wins. Mirrored tier for tier and
  -- boundary for boundary by assessRisk() in lib/domain/risk.ts.
  select
    d.course_id,
    d.tenant_id,
    d.bride_id,
    d.sessions_remaining,
    d.sessions_done,
    d.last_done_at,
    d.stale_cancellations,
    d.target_end_date,
    d.wedding_date,
    d.days_to_deadline,
    case
      when d.days_to_deadline is not null
       and d.sessions_remaining > floor(d.days_to_deadline / 7.0)
        then 'critical'
      when d.stale_cancellations > 0
        then 'high'
      when d.last_done_on is not null
       and d.last_done_on < p_today - 21
        then 'medium'
      when d.wedding_date is not null
       and d.wedding_date <= p_today + 30
        then 'info'
      else 'none'
    end::public.risk_level as risk_level,
    case
      when d.days_to_deadline is not null
       and d.sessions_remaining > floor(d.days_to_deadline / 7.0)
        then 'wont_finish_in_time'
      when d.stale_cancellations > 0
        then 'cancelled_not_rescheduled'
      when d.last_done_on is not null
       and d.last_done_on < p_today - 21
        then 'no_recent_session'
      when d.wedding_date is not null
       and d.wedding_date <= p_today + 30
        then 'wedding_approaching'
      else null
    end as risk_reason_code
  from d
$fn$;

comment on function public.course_risk(date) is
  'v_course_risk''s body, parameterised by the Israeli civil date (issues #38, '
  '#42). security invoker: RLS applies. A course with no target_end_date has '
  'days_to_deadline NULL and cannot rank critical - see migration 0003.';

-- ---------- the view, now on the right clock ----------
-- Same column list, order and types as 0001, so `create or replace` keeps the
-- existing grants. security_invoker = on remains mandatory (SDD §4.2).
create or replace view public.v_course_risk with (security_invoker = on) as
select
  r.course_id,
  r.tenant_id,
  r.bride_id,
  r.sessions_remaining,
  r.sessions_done,
  r.last_done_at,
  r.stale_cancellations,
  r.target_end_date,
  r.wedding_date,
  r.days_to_deadline,
  r.risk_level,
  r.risk_reason_code
from public.course_risk(public.jerusalem_date(now())) as r;

comment on view public.v_course_risk is
  'Risk ranking (SDD 8.1), computed on read against the Asia/Jerusalem civil '
  'date - never the session timezone (#38). days_to_deadline is NULL, never 0, '
  'when the course has no deadline, and such a course cannot rank critical '
  '(#42). Read by the nightly job (8.4) and schema.test.sql.';

-- ---------- grants ----------
-- The view runs as its caller (security_invoker), so the caller needs EXECUTE
-- on both functions. Granted to authenticated only. Revoked by name from anon
-- and service_role as well as PUBLIC, because Supabase's default privileges
-- grant EXECUTE on new public functions to both directly (#31); invariant 5
-- confines service_role to the portal read path, which never reads risk.
revoke execute on function public.jerusalem_date(timestamptz) from public, anon, service_role;
revoke execute on function public.course_risk(date)            from public, anon, service_role;
grant  execute on function public.jerusalem_date(timestamptz) to authenticated;
grant  execute on function public.course_risk(date)            to authenticated;
