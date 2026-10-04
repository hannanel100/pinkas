import "server-only";

import type { CalendarDate } from "@/lib/domain/hebrew-calendar";
import {
  assessRisk,
  type CourseRiskInput,
  type RiskAssessment,
  type RiskLevel,
} from "@/lib/domain/risk";

import { defineRead } from "./context";
import { DataAccessError } from "./internal/errors";
import type { Uuid } from "./internal/ids";
import {
  asRow,
  asRows,
  currencyField,
  enumField,
  intField,
  optionalDateField,
  optionalStringField,
  parseDecimal,
  stringField,
  uuidField,
  type Money,
} from "./internal/values";

/**
 * The Today screen — plate 01, SDD §12.1, §18.1, invariant 10. ADR-0008.
 *
 * ONE round trip: the `today_screen` RPC (migration 0004) returns the risk
 * aggregate, today's sessions and the payment summary as one document, and
 * writes the `access_log` fan-out — one row per bride in the document — in the
 * same statement. So this function writes no log row of its own
 * (`subjects: "database"`; its context has no client for any other query).
 *
 * Risk is computed HERE, by `assessRisk()` with `today` injected, from the
 * aggregate — never `risk_level` from the view. The offline screen (§15) runs
 * the same function over cached rows, so the verdict does not switch on
 * connectivity (ADR-0008; `high` excepted, as recorded there).
 *
 * `last_done_on` is the Israeli civil date computed in-database and is mapped
 * straight to `lastDoneOn`; this module does no timezone arithmetic.
 */

/** One at-risk course: the input and the verdict, so every operand of the reason sentence is present. */
export type RiskRow = {
  readonly input: CourseRiskInput;
  readonly assessment: Exclude<RiskAssessment, { level: "none" }>;
  readonly brideId: Uuid;
  readonly brideFirstName: string;
  readonly courseId: Uuid;
};

export type TodaySession = {
  readonly sessionId: Uuid;
  readonly courseId: Uuid;
  readonly brideId: Uuid;
  readonly brideFirstName: string;
  readonly brideLastName: string | null;
  /** E.164 — the one-tap `wa.me` reminder (§14) needs it. */
  readonly bridePhone: string | null;
  readonly orderIndex: number;
  /** ISO 8601 instant. */
  readonly scheduledAt: string;
  readonly durationMinutes: number;
  readonly location: string | null;
  readonly status: "planned" | "done";
};

export type TodayPayments = {
  /** "One number, detail behind a tap" (note a5). A decimal string, never a float. */
  readonly outstanding: Money;
  readonly openCourseCount: number;
  readonly openBrideCount: number;
  /** Payments in another currency, excluded from the sum rather than mis-added. */
  readonly otherCurrencyPaymentCount: number;
};

export type TodayScreen = {
  readonly today: CalendarDate;
  /** Ordered most severe first, then nearest deadline. Empty = the §8.5 all-clear. */
  readonly risk: readonly RiskRow[];
  /** Active courses with no risk — the "הכל בזמן" count. */
  readonly onTrackCount: number;
  readonly sessionsToday: readonly TodaySession[];
  readonly payments: TodayPayments;
};

const OP = "rpc.today_screen";

const SEVERITY: Readonly<Record<RiskLevel, number>> = {
  critical: 0,
  high: 1,
  medium: 2,
  info: 3,
  none: 4,
};

function byUrgency(a: RiskRow, b: RiskRow): number {
  const s = SEVERITY[a.assessment.level] - SEVERITY[b.assessment.level];
  if (s !== 0) return s;
  const da = a.assessment.daysToDeadline;
  const db = b.assessment.daysToDeadline;
  if (da !== db) {
    if (da === null) return 1;
    if (db === null) return -1;
    return da - db;
  }
  return a.courseId < b.courseId ? -1 : a.courseId > b.courseId ? 1 : 0;
}

export const getTodayScreen = defineRead(
  { resource: "today_screen", subjects: "database" },
  async (ctx): Promise<TodayScreen> => {
    const doc = asRow(OP, await ctx.loggedRpc("today_screen", { p_today: ctx.today }));
    const today = optionalDateField(OP, doc, "today");
    if (today !== ctx.today) throw new DataAccessError(OP, "shape");

    const risk: RiskRow[] = [];
    let onTrackCount = 0;
    for (const c of asRows(OP, doc.courses)) {
      const input: CourseRiskInput = {
        today: ctx.today,
        targetEndDate: optionalDateField(OP, c, "target_end_date"),
        weddingDate: optionalDateField(OP, c, "wedding_date"),
        sessionsRemaining: intField(OP, c, "sessions_remaining"),
        sessionsDone: intField(OP, c, "sessions_done"),
        lastDoneOn: optionalDateField(OP, c, "last_done_on"),
        staleCancellations: intField(OP, c, "stale_cancellations"),
      };
      const assessment = assessRisk(input);
      if (assessment.level === "none") {
        onTrackCount += 1;
        continue;
      }
      risk.push({
        input,
        assessment,
        brideId: uuidField(OP, c, "bride_id"),
        brideFirstName: stringField(OP, c, "bride_first_name"),
        courseId: uuidField(OP, c, "course_id"),
      });
    }
    risk.sort(byUrgency);

    const sessionsToday = asRows(OP, doc.sessions_today).map(
      (s): TodaySession => ({
        sessionId: uuidField(OP, s, "session_id"),
        courseId: uuidField(OP, s, "course_id"),
        brideId: uuidField(OP, s, "bride_id"),
        brideFirstName: stringField(OP, s, "bride_first_name"),
        brideLastName: optionalStringField(OP, s, "bride_last_name"),
        bridePhone: optionalStringField(OP, s, "bride_phone"),
        orderIndex: intField(OP, s, "order_index"),
        scheduledAt: stringField(OP, s, "scheduled_at"),
        durationMinutes: intField(OP, s, "duration_minutes"),
        location: optionalStringField(OP, s, "location"),
        status: enumField(OP, s, "status", ["planned", "done"] as const),
      }),
    );

    const p = asRow(OP, doc.payments);
    const total = parseDecimal(p.outstanding_total, 10);
    if (total === null) throw new DataAccessError(OP, "shape");
    const payments: TodayPayments = {
      outstanding: { amount: total, currency: currencyField(OP, p, "currency") },
      openCourseCount: intField(OP, p, "open_course_count"),
      openBrideCount: intField(OP, p, "open_bride_count"),
      otherCurrencyPaymentCount: intField(OP, p, "other_currency_payment_count"),
    };

    return { today: ctx.today, risk, onTrackCount, sessionsToday, payments };
  },
);
