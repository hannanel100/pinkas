/**
 * The risk engine — SDD §8.
 *
 * ADR-0008: **`assessRisk()` ranks the Today screen, online and offline
 * alike.** Online, `lib/data/today.ts` feeds it the aggregate columns the
 * `today_screen` RPC returns (never the view's verdict); offline (§15),
 * `summariseCourse()` builds the same input from cached rows. One function
 * either way, so the screen cannot change its answer when she loses signal.
 * This module's fixture table is therefore a release gate for the home screen,
 * not an offline convenience.
 *
 * `v_course_risk` (`supabase/migrations/`, last redefined in 0003) remains the
 * source of truth for the nightly job (§8.4), which runs in-database and cannot
 * call TypeScript. The two must agree tier for tier and boundary for boundary,
 * or the nightly notification contradicts the screen she opens in the morning.
 * The view is owned by the `database` agent, so a change to either is a change
 * to both, and saying so out loud is part of changing it.
 *
 * One tier is not fully decided here: `high`. `stale_cancellations` is counted
 * in SQL (inside `course_risk(p_today)`, 7-day threshold embedded) and arrives
 * pre-counted online; only offline does {@link summariseCourse} count it.
 * ADR-0008 accepts that `high` alone can still differ across connectivity.
 *
 * §8.3: the reason code is the feature. This module emits the code and its
 * operands, never a rendered sentence — the sentence is Hebrew and belongs to
 * the translation layer (invariant 8). Never store the rendered sentence.
 *
 * ── One clock, in civil days (#38) ─────────────────────────────────────────
 *
 * The view computes against `jerusalem_date(now())` — the Israeli civil date —
 * through `course_risk(p_today date)`, and every time-based tier is a civil-day
 * comparison in Asia/Jerusalem (§9.4), the same strictly-greater readings this
 * module takes: a cancellation is stale when its date is before `today - 7`,
 * a course is `medium` when its last completed session is before `today - 21`.
 * The two therefore agree exactly, including on the boundary day. (Before
 * migration 0003 the view compared instants against `now()` in the session
 * timezone, and this header documented the resulting hours-wide approximation.)
 *
 * Callers converting `timestamptz` to `CalendarDate` for this module must do
 * so in Asia/Jerusalem, or the agreement is lost at the edge instead.
 *
 * ── A course with no deadline (#42, decided) ───────────────────────────────
 *
 * A course with `target_end_date` null has no `critical` tier and a null
 * `daysToDeadline` — never `0`. "Won't finish in time" is a claim about a
 * deadline, and there is none to miss. The view takes the same reading
 * (migration 0003), stated explicitly rather than left to `greatest()`, which
 * in Postgres *ignores* nulls (`greatest(0, null) = 0`) instead of propagating
 * them — which is how the view used to rank such a course `critical`. Both
 * suites assert the agreed behaviour on the same fixture.
 *
 * Row selection is the caller's job, not this module's: the view restricts to
 * `course.status = 'active'` and `deleted_at is null` on both the course and
 * the bride, and `lib/data/` applies
 * the same filter before calling here.
 *
 * Invariant 4: pure. `today` is injected.
 */

import { addDays, compareDates, diffDays, type CalendarDate } from "./hebrew-calendar";

export type RiskLevel = "none" | "info" | "medium" | "high" | "critical";

export type RiskReasonCode =
  | "wont_finish_in_time"
  | "cancelled_not_rescheduled"
  | "no_recent_session"
  | "wedding_approaching";

/** §8.1 boundaries, named so a change shows up in a diff as a decision. */
export const RISK_THRESHOLDS = {
  /** A cancellation older than this and never rescheduled ranks `high`. */
  staleCancellationDays: 7,
  /** More than this since the last completed session ranks `medium`. */
  noRecentSessionDays: 21,
  /** A wedding within this many days ranks `info`. */
  weddingApproachingDays: 30,
} as const;

/**
 * One row of `v_course_risk`'s `agg` CTE, in domain types.
 *
 * The argument shape is the design call this module had to make: it takes the
 * **aggregate**, not the raw sessions, so the duplicated logic is exactly the
 * view's `case` expression and nothing else. Callers holding raw rows (the
 * offline cache) get the aggregation from {@link summariseCourse}, which
 * mirrors the CTE — so the mirror is split along the same seam as the view.
 */
export type CourseRiskInput = {
  readonly today: CalendarDate;
  /** `course.target_end_date` — the effective deadline (§7.2). */
  readonly targetEndDate: CalendarDate | null;
  /** `bride.wedding_date`. */
  readonly weddingDate: CalendarDate | null;
  /** Sessions still `planned`. */
  readonly sessionsRemaining: number;
  /** Sessions `done`. */
  readonly sessionsDone: number;
  /** Date of the latest `done` session, or `null` if none. */
  readonly lastDoneOn: CalendarDate | null;
  /** Cancellations older than 7 days with no rescheduled successor. */
  readonly staleCancellations: number;
};

/**
 * A risk verdict: the level, the machine-readable reason code, the operands the
 * Hebrew sentence is composed from, and the day count the UI must show beside
 * the colour (invariant 7 — risk is never encoded by colour alone).
 */
export type RiskAssessment =
  | {
      readonly level: "critical";
      readonly reasonCode: "wont_finish_in_time";
      readonly daysToDeadline: number | null;
      readonly operands: {
        readonly sessionsRemaining: number;
        readonly wholeWeeksToDeadline: number;
      };
    }
  | {
      readonly level: "high";
      readonly reasonCode: "cancelled_not_rescheduled";
      readonly daysToDeadline: number | null;
      readonly operands: {
        readonly staleCancellations: number;
        readonly thresholdDays: number;
      };
    }
  | {
      readonly level: "medium";
      readonly reasonCode: "no_recent_session";
      readonly daysToDeadline: number | null;
      readonly operands: {
        readonly daysSinceLastSession: number;
        readonly thresholdDays: number;
      };
    }
  | {
      readonly level: "info";
      readonly reasonCode: "wedding_approaching";
      readonly daysToDeadline: number | null;
      readonly operands: {
        readonly daysToWedding: number;
        readonly thresholdDays: number;
      };
    }
  | {
      readonly level: "none";
      readonly reasonCode: null;
      readonly daysToDeadline: number | null;
    };

/**
 * Mirrors the view's `days_to_deadline`: `greatest(0, target_end_date - p_today)`,
 * and `null` when there is no deadline (the view handles the null explicitly,
 * because Postgres `greatest()` would ignore it and return 0).
 */
export function daysToDeadline(
  today: CalendarDate,
  targetEndDate: CalendarDate | null,
): number | null {
  if (targetEndDate === null) return null;
  return Math.max(0, diffDays(targetEndDate, today));
}

/**
 * The five tiers of §8.1, evaluated in order — **first match wins**, exactly as
 * the view's `case` expression does.
 */
export function assessRisk(input: CourseRiskInput): RiskAssessment {
  const deadlineDays = daysToDeadline(input.today, input.targetEndDate);

  // critical — sessions remaining > whole weeks to the effective deadline.
  // A null deadline skips the tier: a course with no deadline cannot be failing
  // to meet one. The view takes the same reading — see the header.
  if (deadlineDays !== null) {
    const wholeWeeks = Math.floor(deadlineDays / 7);
    if (input.sessionsRemaining > wholeWeeks) {
      return {
        level: "critical",
        reasonCode: "wont_finish_in_time",
        daysToDeadline: deadlineDays,
        operands: {
          sessionsRemaining: input.sessionsRemaining,
          wholeWeeksToDeadline: wholeWeeks,
        },
      };
    }
  }

  // high — a cancellation more than 7 days old that was never rescheduled.
  if (input.staleCancellations > 0) {
    return {
      level: "high",
      reasonCode: "cancelled_not_rescheduled",
      daysToDeadline: deadlineDays,
      operands: {
        staleCancellations: input.staleCancellations,
        thresholdDays: RISK_THRESHOLDS.staleCancellationDays,
      },
    };
  }

  // medium — more than 21 days since the last completed session. A course that
  // has never had one does not qualify: the view's `last_done_at is not null`.
  if (input.lastDoneOn !== null) {
    const since = diffDays(input.today, input.lastDoneOn);
    if (since > RISK_THRESHOLDS.noRecentSessionDays) {
      return {
        level: "medium",
        reasonCode: "no_recent_session",
        daysToDeadline: deadlineDays,
        operands: {
          daysSinceLastSession: since,
          thresholdDays: RISK_THRESHOLDS.noRecentSessionDays,
        },
      };
    }
  }

  // info — wedding within 30 days and the course otherwise on track.
  if (input.weddingDate !== null) {
    const horizon = addDays(input.today, RISK_THRESHOLDS.weddingApproachingDays);
    if (compareDates(input.weddingDate, horizon) <= 0) {
      return {
        level: "info",
        reasonCode: "wedding_approaching",
        daysToDeadline: deadlineDays,
        operands: {
          daysToWedding: diffDays(input.weddingDate, input.today),
          thresholdDays: RISK_THRESHOLDS.weddingApproachingDays,
        },
      };
    }
  }

  return { level: "none", reasonCode: null, daysToDeadline: deadlineDays };
}

/* ── The aggregation half of the mirror ───────────────────────────────────── */

/** One `session` row, reduced to what the risk view actually reads. */
export type SessionSnapshot = {
  readonly id: string;
  readonly status: "planned" | "done" | "cancelled" | "rescheduled";
  /** `scheduled_at` as a civil date; `null` = "טרם נקבע". */
  readonly scheduledOn: CalendarDate | null;
  /** `session.rescheduled_from_session_id`. */
  readonly rescheduledFromSessionId?: string | null;
};

/**
 * Mirrors the view's `agg` CTE: counts, the last completed session, and stale
 * cancellations. Soft-deleted rows are excluded by the caller, as in the view's
 * `left join ... and s.deleted_at is null`.
 */
export function summariseCourse(args: {
  readonly today: CalendarDate;
  readonly targetEndDate: CalendarDate | null;
  readonly weddingDate: CalendarDate | null;
  readonly sessions: readonly SessionSnapshot[];
}): CourseRiskInput {
  const rescheduledFrom = new Set<string>();
  for (const session of args.sessions) {
    if (session.rescheduledFromSessionId) {
      rescheduledFrom.add(session.rescheduledFromSessionId);
    }
  }

  let sessionsRemaining = 0;
  let sessionsDone = 0;
  let lastDoneOn: CalendarDate | null = null;
  let staleCancellations = 0;
  const staleBefore = addDays(
    args.today,
    -RISK_THRESHOLDS.staleCancellationDays,
  );

  for (const session of args.sessions) {
    switch (session.status) {
      case "planned":
        sessionsRemaining += 1;
        break;
      case "done":
        sessionsDone += 1;
        if (
          session.scheduledOn !== null &&
          (lastDoneOn === null ||
            compareDates(session.scheduledOn, lastDoneOn) > 0)
        ) {
          lastDoneOn = session.scheduledOn;
        }
        break;
      case "cancelled":
        // `jerusalem_date(scheduled_at) < p_today - 7` — null is never less than
        // anything in SQL, so an unscheduled cancellation is not stale.
        if (
          session.scheduledOn !== null &&
          compareDates(session.scheduledOn, staleBefore) < 0 &&
          !rescheduledFrom.has(session.id)
        ) {
          staleCancellations += 1;
        }
        break;
      default:
        break;
    }
  }

  return {
    today: args.today,
    targetEndDate: args.targetEndDate,
    weddingDate: args.weddingDate,
    sessionsRemaining,
    sessionsDone,
    lastDoneOn,
    staleCancellations,
  };
}
