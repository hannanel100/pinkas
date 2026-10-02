import { describe, expect, it } from "vitest";

import { parseCalendarDate } from "@/lib/domain/hebrew-calendar";
import type { RiskAssessment } from "@/lib/domain/risk";

import {
  fill,
  formatClock,
  formatDate,
  formatDayMonth,
  formatFraction,
  formatShekels,
  metric,
  t,
  toText,
} from "./index";

type AtRisk = Exclude<RiskAssessment, { level: "none" }>;

const critical = (sessionsRemaining: number): AtRisk => ({
  level: "critical",
  reasonCode: "wont_finish_in_time",
  daysToDeadline: 18,
  operands: { sessionsRemaining, wholeWeeksToDeadline: 2 },
});

const high = (staleCancellations: number): AtRisk => ({
  level: "high",
  reasonCode: "cancelled_not_rescheduled",
  daysToDeadline: 9,
  operands: { staleCancellations, thresholdDays: 7 },
});

const medium = (daysSinceLastSession: number): AtRisk => ({
  level: "medium",
  reasonCode: "no_recent_session",
  daysToDeadline: 24,
  operands: { daysSinceLastSession, thresholdDays: 21 },
});

const info = (daysToWedding: number): AtRisk => ({
  level: "info",
  reasonCode: "wedding_approaching",
  daysToDeadline: 12,
  operands: { daysToWedding, thresholdDays: 30 },
});

describe("day counts read correctly in Hebrew", () => {
  it.each([
    [0, "0 ימים"],
    [1, "יום אחד"],
    [2, "יומיים"],
    [3, "3 ימים"],
    [9, "9 ימים"], // wireframe plate 01
    [10, "10 ימים"],
    [11, "11 יום"],
    [18, "18 יום"], // wireframe plates 01 and 02
    [24, "24 יום"], // wireframe plate 01
  ])("%i → %s", (n, expected) => {
    expect(toText(t.count.days(n))).toBe(expected);
  });

  it("sets the numeral as a metric and the noun as prose", () => {
    expect(t.count.days(18)).toEqual([metric(18), " יום"]);
    expect(t.count.days(9)).toEqual([metric(9), " ימים"]);
  });

  it("has no numeral to set in mono when Hebrew uses a word", () => {
    expect(t.count.days(1)).toEqual(["יום אחד"]);
    expect(t.count.days(2)).toEqual(["יומיים"]);
  });

  it("rejects a count that is not a non-negative integer", () => {
    expect(() => t.count.days(-1)).toThrow(RangeError);
    expect(() => t.count.days(1.5)).toThrow(RangeError);
  });

  it("counts sessions as prose", () => {
    expect(t.count.sessions(1)).toBe("מפגש אחד");
    expect(t.count.sessions(2)).toBe("2 מפגשים");
    expect(t.count.sessions(12)).toBe("12 מפגשים");
  });
});

describe("risk sentences are composed from code + operands (§8.3)", () => {
  it("matches the wireframe's plate 01 rows", () => {
    expect(t.risk.reason(critical(4))).toBe("4 מפגשים נותרו · לא ייגמר בזמן");
    expect(t.risk.reason(high(1))).toBe("מפגש בוטל ולא תוזמן מחדש");
  });

  it("agrees in number for one and for n", () => {
    expect(t.risk.reason(critical(1))).toBe("מפגש אחד נותר · לא ייגמר בזמן");
    expect(t.risk.reason(high(2))).toBe("2 מפגשים בוטלו ולא תוזמנו מחדש");
    expect(t.risk.reason(medium(22))).toBe("אין מפגש מזה 22 יום");
    expect(t.risk.reason(info(1))).toBe("החתונה בעוד יום אחד · המסלול בזמן");
    expect(t.risk.reason(info(5))).toBe("החתונה בעוד 5 ימים · המסלול בזמן");
  });

  it("says something true on the wedding day and after it", () => {
    expect(t.risk.reason(info(0))).toBe("החתונה היום · המסלול בזמן");
    expect(t.risk.reason(info(-3))).toBe("תאריך החתונה עבר");
  });

  it("renders a different sentence when the operands change", () => {
    // The sentence is derived, never stored: same code, new operands, new copy.
    expect(t.risk.reason(critical(4))).not.toBe(t.risk.reason(critical(5)));
  });
});

describe("the §8.5 empty state", () => {
  it("reads exactly as the wireframe specifies", () => {
    expect(t.today.allClear(2)).toBe("הכל בזמן. 2 מפגשים היום.");
  });

  it("stays one sentence for one session and for none", () => {
    expect(t.today.allClear(1)).toBe("הכל בזמן. מפגש אחד היום.");
    expect(t.today.allClear(0)).toBe("הכל בזמן. אין מפגשים היום.");
  });
});

describe("fill", () => {
  it("splices prose and splits out metrics", () => {
    expect(fill("עד {date} · {who}", { date: metric("10.09"), who: "מיכל" })).toEqual([
      "עד ",
      metric("10.09"),
      " · מיכל",
    ]);
  });

  it("throws on a missing operand rather than rendering the placeholder", () => {
    expect(() => fill("{n} ימים", {})).toThrow(/Missing operand/);
  });
});

describe("quantity formatters", () => {
  it("formats wall-clock time in Asia/Jerusalem, 24-hour", () => {
    // 14:00Z is 17:00 in Israel in summer (IDT, UTC+3), 16:00 in winter.
    expect(formatClock(new Date("2026-07-20T14:00:00Z"))).toBe("17:00");
    expect(formatClock(new Date("2026-12-20T14:00:00Z"))).toBe("16:00");
    expect(formatClock(new Date("2026-07-20T17:30:00Z"))).toBe("20:30");
  });

  it("formats dates as the wireframe sets them", () => {
    expect(formatDayMonth(parseCalendarDate("2026-07-12"))).toBe("12.07");
    expect(formatDate(parseCalendarDate("2026-09-10"))).toBe("10.09.2026");
  });

  it("formats shekels symbol-first with Latin grouping", () => {
    expect(formatShekels(2400)).toBe("₪2,400");
    expect(formatShekels(350.5)).toBe("₪350.50");
    expect(formatShekels(-120)).toBe("-₪120");
  });

  it("formats a progress fraction", () => {
    expect(formatFraction(4, 8)).toBe("4 / 8");
  });
});
