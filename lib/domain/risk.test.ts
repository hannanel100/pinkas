/**
 * Fixture tables for `risk.ts` — SDD §8, §17.2.
 *
 * §17.2 asks for each tier **at its boundary**: exactly 21 days, exactly 7
 * days, exactly at the deadline — plus a course with zero sessions. The rows
 * below pair each boundary with the day either side of it, because a tier that
 * is right in the middle and wrong at the edge is the failure mode that matters
 * on the Today screen.
 *
 * `v_course_risk` in `schema.sql` remains the source of truth. The fixtures
 * mirror the view's own test data in `schema.test.sql` where they overlap.
 */

import { describe, expect, it } from "vitest";

import { addDays, parseCalendarDate, type CalendarDate } from "./hebrew-calendar";
import {
  assessRisk,
  summariseCourse,
  type CourseRiskInput,
  type RiskAssessment,
  type SessionSnapshot,
} from "./risk";

const TODAY = parseCalendarDate("2026-06-01");
const day = (offset: number): CalendarDate => addDays(TODAY, offset);

const course = (
  overrides: Partial<CourseRiskInput> = {},
): CourseRiskInput => ({
  today: TODAY,
  targetEndDate: day(200),
  weddingDate: day(214),
  sessionsRemaining: 0,
  sessionsDone: 0,
  lastDoneOn: null,
  staleCancellations: 0,
  ...overrides,
});

type Row = {
  readonly name: string;
  readonly input: CourseRiskInput;
  readonly level: RiskAssessment["level"];
  readonly reasonCode: RiskAssessment["reasonCode"];
};

const rows: readonly Row[] = [
  /* ── critical: sessions remaining > whole weeks to the deadline ─────────── */
  {
    name: "critical — 5 sessions, 2 whole weeks left (schema.test.sql's row)",
    input: course({ targetEndDate: day(14), sessionsRemaining: 5 }),
    level: "critical",
    reasonCode: "wont_finish_in_time",
  },
  {
    name: "critical — 3 sessions, exactly 2 whole weeks left",
    input: course({ targetEndDate: day(14), sessionsRemaining: 3 }),
    level: "critical",
    reasonCode: "wont_finish_in_time",
  },
  {
    name: "not critical — 2 sessions, exactly 2 whole weeks left (boundary)",
    input: course({
      targetEndDate: day(14),
      weddingDate: day(28),
      sessionsRemaining: 2,
    }),
    level: "info",
    reasonCode: "wedding_approaching",
  },
  {
    name: "critical — 1 session, 6 days left (0 whole weeks)",
    input: course({ targetEndDate: day(6), sessionsRemaining: 1 }),
    level: "critical",
    reasonCode: "wont_finish_in_time",
  },
  {
    name: "critical — 1 session left, exactly at the deadline",
    input: course({ targetEndDate: day(0), sessionsRemaining: 1 }),
    level: "critical",
    reasonCode: "wont_finish_in_time",
  },
  {
    name: "critical — deadline already passed, sessions outstanding",
    input: course({ targetEndDate: day(-10), sessionsRemaining: 1 }),
    level: "critical",
    reasonCode: "wont_finish_in_time",
  },
  {
    name: "not critical — zero sessions remaining, exactly at the deadline",
    input: course({
      targetEndDate: day(0),
      weddingDate: day(14),
      sessionsRemaining: 0,
    }),
    level: "info",
    reasonCode: "wedding_approaching",
  },
  {
    name: "not critical — no target end date, so the tier cannot fire",
    input: course({ targetEndDate: null, sessionsRemaining: 20 }),
    level: "none",
    reasonCode: null,
  },

  /* ── high: a cancellation older than 7 days, never rescheduled ──────────── */
  {
    name: "high — one stale cancellation",
    input: course({ staleCancellations: 1 }),
    level: "high",
    reasonCode: "cancelled_not_rescheduled",
  },
  {
    name: "high outranks medium",
    input: course({ staleCancellations: 1, lastDoneOn: day(-40) }),
    level: "high",
    reasonCode: "cancelled_not_rescheduled",
  },
  {
    name: "critical outranks high",
    input: course({
      targetEndDate: day(7),
      sessionsRemaining: 4,
      staleCancellations: 2,
    }),
    level: "critical",
    reasonCode: "wont_finish_in_time",
  },

  /* ── medium: more than 21 days since the last completed session ─────────── */
  {
    name: "not medium — exactly 21 days since the last session (boundary)",
    input: course({ lastDoneOn: day(-21) }),
    level: "none",
    reasonCode: null,
  },
  {
    name: "medium — 22 days since the last session",
    input: course({ lastDoneOn: day(-22) }),
    level: "medium",
    reasonCode: "no_recent_session",
  },
  {
    name: "medium — 30 days, as in schema.test.sql",
    input: course({ lastDoneOn: day(-30), sessionsDone: 1 }),
    level: "medium",
    reasonCode: "no_recent_session",
  },
  {
    name: "not medium — no completed session has ever happened",
    input: course({ lastDoneOn: null }),
    level: "none",
    reasonCode: null,
  },
  {
    name: "medium outranks info",
    input: course({ lastDoneOn: day(-40), weddingDate: day(10) }),
    level: "medium",
    reasonCode: "no_recent_session",
  },

  /* ── info: wedding within 30 days ───────────────────────────────────────── */
  {
    name: "info — wedding in exactly 30 days (boundary)",
    input: course({ weddingDate: day(30) }),
    level: "info",
    reasonCode: "wedding_approaching",
  },
  {
    name: "none — wedding in 31 days",
    input: course({ weddingDate: day(31) }),
    level: "none",
    reasonCode: null,
  },
  {
    name: "info — wedding today",
    input: course({ weddingDate: day(0), targetEndDate: day(0) }),
    level: "info",
    reasonCode: "wedding_approaching",
  },
  {
    name: "info — the view treats a past wedding as approaching too",
    input: course({ weddingDate: day(-3), targetEndDate: day(-17) }),
    level: "info",
    reasonCode: "wedding_approaching",
  },
  {
    name: "none — no wedding date on file",
    input: course({ weddingDate: null }),
    level: "none",
    reasonCode: null,
  },

  /* ── none: the healthy course, and the empty one (§8.5) ─────────────────── */
  {
    name: "none — healthy course, as in schema.test.sql",
    input: course({
      targetEndDate: day(200),
      weddingDate: day(214),
      sessionsRemaining: 1,
      sessionsDone: 1,
      lastDoneOn: day(-2),
    }),
    level: "none",
    reasonCode: null,
  },
  {
    name: "none — a course with zero sessions and a distant wedding (§17.2)",
    input: course({ sessionsRemaining: 0, sessionsDone: 0 }),
    level: "none",
    reasonCode: null,
  },
];

describe("assessRisk mirrors v_course_risk (§8.1)", () => {
  it.each(rows)("$name", (row) => {
    const assessment = assessRisk(row.input);
    expect(assessment.level).toBe(row.level);
    expect(assessment.reasonCode).toBe(row.reasonCode);
  });

  it("reports operands, never a rendered sentence (§8.3)", () => {
    const critical = assessRisk(
      course({ targetEndDate: day(14), sessionsRemaining: 4 }),
    );
    expect(critical).toEqual({
      level: "critical",
      reasonCode: "wont_finish_in_time",
      daysToDeadline: 14,
      operands: { sessionsRemaining: 4, wholeWeeksToDeadline: 2 },
    });

    const medium = assessRisk(course({ lastDoneOn: day(-25) }));
    expect(medium).toEqual({
      level: "medium",
      reasonCode: "no_recent_session",
      daysToDeadline: 200,
      operands: { daysSinceLastSession: 25, thresholdDays: 21 },
    });

    const info = assessRisk(course({ weddingDate: day(18) }));
    expect(info).toEqual({
      level: "info",
      reasonCode: "wedding_approaching",
      daysToDeadline: 200,
      operands: { daysToWedding: 18, thresholdDays: 30 },
    });

    const high = assessRisk(course({ staleCancellations: 2 }));
    expect(high).toEqual({
      level: "high",
      reasonCode: "cancelled_not_rescheduled",
      daysToDeadline: 200,
      operands: { staleCancellations: 2, thresholdDays: 7 },
    });
  });

  it("floors days to the deadline at zero, as greatest(0, …) does", () => {
    expect(assessRisk(course({ targetEndDate: day(-5) })).daysToDeadline).toBe(
      0,
    );
    expect(assessRisk(course({ targetEndDate: null })).daysToDeadline).toBeNull();
  });
});

describe("summariseCourse mirrors the view's agg CTE", () => {
  const session = (
    id: string,
    status: SessionSnapshot["status"],
    offset: number | null,
    rescheduledFromSessionId?: string,
  ): SessionSnapshot => ({
    id,
    status,
    scheduledOn: offset === null ? null : day(offset),
    ...(rescheduledFromSessionId === undefined
      ? {}
      : { rescheduledFromSessionId }),
  });

  it("counts planned and done sessions and finds the last completed one", () => {
    const summary = summariseCourse({
      today: TODAY,
      targetEndDate: day(60),
      weddingDate: day(74),
      sessions: [
        session("s1", "done", -30),
        session("s2", "done", -10),
        session("s3", "planned", 3),
        session("s4", "planned", 10),
        session("s5", "rescheduled", -5),
      ],
    });
    expect(summary.sessionsDone).toBe(2);
    expect(summary.sessionsRemaining).toBe(2);
    expect(summary.lastDoneOn).toBe(day(-10));
    expect(summary.staleCancellations).toBe(0);
  });

  const cancellations: ReadonlyArray<[string, number, boolean, number]> = [
    ["cancelled 8 days ago, never rescheduled", -8, false, 1],
    ["cancelled exactly 7 days ago (boundary)", -7, false, 0],
    ["cancelled 6 days ago", -6, false, 0],
    ["cancelled 10 days ago but rescheduled", -10, true, 0],
  ];

  it.each(cancellations)("%s", (_label, offset, rescheduled, expected) => {
    const sessions: SessionSnapshot[] = [session("c1", "cancelled", offset)];
    if (rescheduled) sessions.push(session("c2", "planned", 3, "c1"));
    const summary = summariseCourse({
      today: TODAY,
      targetEndDate: day(60),
      weddingDate: day(74),
      sessions,
    });
    expect(summary.staleCancellations).toBe(expected);
  });

  it("does not treat an unscheduled cancellation as stale (null in SQL)", () => {
    const summary = summariseCourse({
      today: TODAY,
      targetEndDate: day(60),
      weddingDate: day(74),
      sessions: [session("c1", "cancelled", null)],
    });
    expect(summary.staleCancellations).toBe(0);
  });

  it("summarises a course with no sessions at all (§8.5)", () => {
    const summary = summariseCourse({
      today: TODAY,
      targetEndDate: day(60),
      weddingDate: day(74),
      sessions: [],
    });
    expect(summary).toEqual({
      today: TODAY,
      targetEndDate: day(60),
      weddingDate: day(74),
      sessionsRemaining: 0,
      sessionsDone: 0,
      lastDoneOn: null,
      staleCancellations: 0,
    });
    expect(assessRisk(summary).level).toBe("none");
  });

  it("ranks the whole schema.test.sql high fixture end to end", () => {
    const summary = summariseCourse({
      today: TODAY,
      targetEndDate: day(200),
      weddingDate: day(214),
      sessions: [
        session("h1", "cancelled", -10),
        session("h2", "planned", 3),
      ],
    });
    const assessment = assessRisk(summary);
    expect(assessment.level).toBe("high");
    expect(assessment.reasonCode).toBe("cancelled_not_rescheduled");
  });
});
