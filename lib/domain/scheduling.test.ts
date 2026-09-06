/**
 * Fixture tables for `scheduling.ts` — SDD §7, §17.2.
 *
 * §17.2 names the cases that must be covered: Tisha B'Av mid-course, a wedding
 * closer than the buffer, a wedding inside the buffer, Hebrew leap years,
 * multi-day Yom Tov, a cadence that cannot fit, every session pinned, and a
 * blackout colliding with a pinned session. Each is a row below.
 *
 * Two things the table checks for every row, not just the interesting ones:
 * no proposed session ever lands on an unavailable day, and every non-`ok`
 * feasibility carries a remedy that actually resolves the problem (§7.4) —
 * except where a row says otherwise and says why.
 */

import { describe, expect, it } from "vitest";

import {
  calendarUnavailability,
  compareDates,
  parseCalendarDate,
  type CalendarDate,
} from "./hebrew-calendar";
import {
  DEFAULT_BUFFER_DAYS,
  effectiveDeadline,
  proposeSchedule,
  type Feasibility,
  type FeasibilityCode,
  type Remedy,
  type ScheduleInput,
  type ScheduleProposal,
} from "./scheduling";

const d = (value: string): CalendarDate => parseCalendarDate(value);

const TOPICS = [
  { id: "t1", title: "הלכות נידה" },
  { id: "t2", title: "טהרה" },
  { id: "t3", title: "הכנה למקווה" },
  { id: "t4", title: "חיי אישות" },
  { id: "t5", title: "שלום בית" },
  { id: "t6", title: "צניעות" },
  { id: "t7", title: "ברכות" },
  { id: "t8", title: "סיכום" },
];

type Fixture = {
  readonly name: string;
  readonly input: ScheduleInput;
  readonly expect: {
    readonly status: "ok" | "tight" | "infeasible";
    readonly message?: FeasibilityCode;
    readonly slotDates?: readonly string[];
    readonly skips?: ReadonlyArray<readonly [string, string]>;
    readonly remedy?: Remedy;
    readonly remedyKind?: Remedy["kind"];
    /** Set false where the remedy unblocks the constraint without fixing it. */
    readonly remedyResolves?: boolean;
  };
};

const base = {
  blackouts: [],
  pinned: [],
} satisfies Pick<ScheduleInput, "blackouts" | "pinned">;

const fixtures: readonly Fixture[] = [
  {
    // Plate 03's own example: the walk lands on 9 Av and steps over it, and the
    // skip is in the output so the instructor sees competence, not a bug (§7.6).
    name: "Tisha B'Av mid-course",
    input: {
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-08-20"),
      sessionCount: 8,
      cadence: { kind: "perWeek", n: 1 },
      earliestStart: d("2026-06-01"),
      bufferDays: 14,
      topics: TOPICS,
    },
    expect: {
      status: "ok",
      slotDates: [
        "2026-06-17",
        "2026-06-24",
        "2026-07-01",
        "2026-07-08",
        "2026-07-15",
        "2026-07-22",
        "2026-07-30",
        "2026-08-06",
      ],
      skips: [["2026-07-23", "fastDay"]],
    },
  },
  {
    // The wedding is nearer than the buffer, so the effective deadline is
    // already behind us. Shortening the buffer is the change that helps.
    name: "a wedding closer than the buffer",
    input: {
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-06-10"),
      sessionCount: 2,
      cadence: { kind: "perWeek", n: 1 },
      earliestStart: d("2026-06-01"),
      bufferDays: 14,
    },
    expect: {
      status: "infeasible",
      message: "deadline_in_the_past",
      slotDates: [],
      remedy: { kind: "reduceBuffer", days: 2 },
    },
  },
  {
    // Today sits inside the buffer window and four sessions are outstanding.
    // Nothing fits at any buffer, so the engine drops the buffer entirely
    // rather than telling her to teach nothing — see findRemedy's last block.
    name: "a wedding inside the buffer",
    input: {
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-06-08"),
      sessionCount: 4,
      cadence: { kind: "perWeek", n: 1 },
      earliestStart: d("2026-06-01"),
      bufferDays: 14,
    },
    expect: {
      status: "infeasible",
      message: "deadline_in_the_past",
      slotDates: [],
      remedy: { kind: "reduceBuffer", days: 0 },
      remedyResolves: false,
    },
  },
  {
    name: "a cadence that cannot fit",
    input: {
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-08-20"),
      sessionCount: 20,
      cadence: { kind: "perWeek", n: 1 },
      earliestStart: d("2026-06-01"),
      bufferDays: 14,
    },
    expect: {
      status: "infeasible",
      message: "not_enough_available_days",
      remedyKind: "increaseCadence",
    },
  },
  {
    // Rosh Hashana runs two days and Tzom Gedaliah follows it: three
    // consecutive unavailable days, each reported separately.
    name: "multi-day Yom Tov",
    input: {
      ...base,
      today: d("2026-09-01"),
      weddingDate: d("2026-09-29"),
      sessionCount: 3,
      cadence: { kind: "everyNDays", n: 1 },
      earliestStart: d("2026-09-01"),
      bufferDays: 14,
    },
    expect: {
      status: "ok",
      slotDates: ["2026-09-10", "2026-09-11", "2026-09-15"],
      skips: [
        ["2026-09-12", "yomTov"],
        ["2026-09-13", "yomTov"],
        ["2026-09-14", "fastDay"],
      ],
    },
  },
  {
    // 5787 has thirteen months. The wedding was given as 12 Adar II and the
    // course runs back through Adar I into Sh'vat — civil-day arithmetic does
    // not care, which is the point of §9.4.
    name: "Hebrew leap year (5787, Adar I and Adar II)",
    input: {
      ...base,
      today: d("2027-01-01"),
      weddingDate: d("2027-03-21"),
      sessionCount: 6,
      cadence: { kind: "perWeek", n: 1 },
      earliestStart: d("2027-01-01"),
      bufferDays: 14,
    },
    expect: {
      status: "ok",
      slotDates: [
        "2027-01-31",
        "2027-02-07",
        "2027-02-14",
        "2027-02-21",
        "2027-02-28",
        "2027-03-07",
      ],
      skips: [],
    },
  },
  {
    name: "every session pinned",
    input: {
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-08-20"),
      sessionCount: 4,
      cadence: { kind: "perWeek", n: 1 },
      earliestStart: d("2026-06-01"),
      bufferDays: 14,
      pinned: [
        { orderIndex: 1, date: d("2026-06-03") },
        { orderIndex: 2, date: d("2026-06-10") },
        { orderIndex: 3, date: d("2026-06-17") },
        { orderIndex: 4, date: d("2026-06-24") },
      ],
    },
    expect: {
      status: "ok",
      slotDates: ["2026-06-03", "2026-06-10", "2026-06-17", "2026-06-24"],
      skips: [],
    },
  },
  {
    // A pinned session inside a blackout is kept — pinned means immovable, and
    // she may know something the system does not (§7.5, note c4) — but it is
    // flagged on the slot rather than silently accepted.
    name: "a blackout colliding with a pinned session",
    input: {
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-08-20"),
      sessionCount: 4,
      cadence: { kind: "perWeek", n: 1 },
      earliestStart: d("2026-06-01"),
      bufferDays: 14,
      blackouts: [
        {
          id: "blk-1",
          startsOn: d("2026-06-10"),
          endsOn: d("2026-06-12"),
          reason: "חופשה",
        },
      ],
      pinned: [
        { orderIndex: 1, date: d("2026-06-03") },
        { orderIndex: 2, date: d("2026-06-10") },
        { orderIndex: 3, date: d("2026-06-17") },
        { orderIndex: 4, date: d("2026-06-24") },
      ],
    },
    expect: {
      status: "ok",
      slotDates: ["2026-06-03", "2026-06-10", "2026-06-17", "2026-06-24"],
      skips: [],
    },
  },
  {
    // A blackout range and a fast day in one walk: the two report differently,
    // because "skipped · unavailable" and "skipped · Tzom Tammuz" are different
    // sentences to the reader (§7.6).
    name: "a blackout range and a fast day in the same walk",
    input: {
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-07-16"),
      sessionCount: 3,
      cadence: { kind: "perWeek", n: 1 },
      earliestStart: d("2026-06-01"),
      bufferDays: 14,
      blackouts: [
        { id: "blk-2", startsOn: d("2026-06-22"), endsOn: d("2026-06-26") },
      ],
    },
    expect: {
      status: "ok",
      slotDates: ["2026-06-14", "2026-06-21", "2026-07-01"],
      skips: [
        ["2026-06-22", "blackout"],
        ["2026-06-23", "blackout"],
        ["2026-06-24", "blackout"],
        ["2026-07-02", "fastDay"],
      ],
    },
  },
  {
    // It fits, and there is no room left for the cancellation that will happen.
    // §7.4: warn now, with a way out.
    name: "fits with no slack",
    input: {
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-07-02"),
      sessionCount: 3,
      cadence: { kind: "perWeek", n: 1 },
      earliestStart: d("2026-06-01"),
      bufferDays: 14,
    },
    expect: {
      status: "tight",
      message: "no_slack",
      slotDates: ["2026-06-04", "2026-06-11", "2026-06-18"],
      remedy: { kind: "increaseCadence", perWeek: 2, forWeeks: 3 },
    },
  },
  {
    // §7.5 recomputation: completed sessions never move, everything else
    // reflows around them.
    name: "recomputation keeps completed sessions where they are",
    input: {
      ...base,
      today: d("2026-07-01"),
      weddingDate: d("2026-08-20"),
      sessionCount: 6,
      cadence: { kind: "perWeek", n: 1 },
      earliestStart: d("2026-07-01"),
      bufferDays: 14,
      pinned: [
        { orderIndex: 1, date: d("2026-06-03"), kind: "completed" },
        { orderIndex: 2, date: d("2026-06-10"), kind: "completed" },
      ],
    },
    expect: {
      status: "ok",
      slotDates: [
        "2026-06-03",
        "2026-06-10",
        "2026-07-15",
        "2026-07-22",
        "2026-07-30",
        "2026-08-06",
      ],
      skips: [["2026-07-23", "fastDay"]],
    },
  },
  {
    name: "a course with no sessions",
    input: {
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-08-20"),
      sessionCount: 0,
      cadence: { kind: "perWeek", n: 1 },
      earliestStart: d("2026-06-01"),
      bufferDays: 14,
    },
    expect: { status: "ok", slotDates: [], skips: [] },
  },
];

/** Re-runs the proposal with a remedy applied, to prove the remedy is real. */
function applyRemedy(input: ScheduleInput, remedy: Remedy): ScheduleInput {
  switch (remedy.kind) {
    case "increaseCadence":
      return { ...input, cadence: { kind: "perWeek", n: remedy.perWeek } };
    case "startEarlier":
      return { ...input, earliestStart: remedy.date };
    case "reduceBuffer":
      return { ...input, bufferDays: remedy.days };
    case "reduceSessions":
      return {
        ...input,
        sessionCount: remedy.to,
        pinned: input.pinned.filter((slot) => slot.orderIndex <= remedy.to),
      };
  }
}

describe.each(fixtures)("$name", (fixture) => {
  const proposal: ScheduleProposal = proposeSchedule(fixture.input);

  it("reports the expected feasibility", () => {
    expect(proposal.feasibility.status).toBe(fixture.expect.status);
    if (fixture.expect.message !== undefined) {
      expect(
        proposal.feasibility.status === "ok"
          ? undefined
          : proposal.feasibility.message,
      ).toBe(fixture.expect.message);
    }
  });

  if (fixture.expect.slotDates !== undefined) {
    it("places the expected dates", () => {
      expect(proposal.slots.map((slot) => slot.date)).toEqual(
        fixture.expect.slotDates,
      );
    });
  }

  if (fixture.expect.skips !== undefined) {
    it("reports every skipped day with its reason", () => {
      expect(
        proposal.skips.map((skip) => [skip.date, skip.reason.kind] as const),
      ).toEqual(fixture.expect.skips);
    });
  }

  if (fixture.expect.remedy !== undefined) {
    it("offers the expected remedy", () => {
      expect(
        proposal.feasibility.status === "ok"
          ? undefined
          : proposal.feasibility.remedy,
      ).toEqual(fixture.expect.remedy);
    });
  }

  if (fixture.expect.remedyKind !== undefined) {
    it(`offers a ${fixture.expect.remedyKind} remedy`, () => {
      expect(
        proposal.feasibility.status === "ok"
          ? undefined
          : proposal.feasibility.remedy.kind,
      ).toBe(fixture.expect.remedyKind);
    });
  }

  it("returns slots in ascending date and order-index order", () => {
    const dates = proposal.slots.map((slot) => slot.date);
    expect(dates).toEqual([...dates].sort(compareDates));
    expect(new Set(dates).size).toBe(dates.length);

    const indexes = proposal.slots.map((slot) => slot.orderIndex);
    expect(indexes).toEqual([...indexes].sort((a, b) => a - b));
    expect(new Set(indexes).size).toBe(indexes.length);

    // A schedule that fits covers 1..n. An infeasible one returns the sessions
    // it *could* place — the later ones, since the walk runs backward — so the
    // partial output keeps their real order indexes rather than renumbering.
    if (proposal.feasibility.status !== "infeasible") {
      expect(indexes).toEqual(indexes.map((_index, i) => i + 1));
    }
    expect(indexes.at(-1) ?? 0).toBeLessThanOrEqual(fixture.input.sessionCount);
  });

  it("never proposes a session on an unavailable day", () => {
    const blackout = (date: CalendarDate) =>
      fixture.input.blackouts.some(
        (range) =>
          compareDates(date, range.startsOn) >= 0 &&
          compareDates(date, range.endsOn) <= 0,
      );
    for (const slot of proposal.slots) {
      if (slot.source !== "proposed") continue;
      expect(calendarUnavailability(slot.date)).toBeNull();
      expect(blackout(slot.date)).toBe(false);
    }
  });

  it("proposes nothing before the earliest start or after the deadline", () => {
    const deadline = effectiveDeadline(
      fixture.input.weddingDate,
      fixture.input.bufferDays,
    );
    for (const slot of proposal.slots) {
      if (slot.source !== "proposed") continue;
      expect(compareDates(slot.date, fixture.input.earliestStart)).toBeGreaterThanOrEqual(0);
      expect(compareDates(slot.date, fixture.input.today)).toBeGreaterThanOrEqual(0);
      expect(compareDates(slot.date, deadline)).toBeLessThanOrEqual(0);
    }
  });

  if (fixture.expect.status !== "ok") {
    it("carries a remedy that resolves the problem", () => {
      if (proposal.feasibility.status === "ok") throw new Error("unreachable");
      const remedy = proposal.feasibility.remedy;
      expect(remedy).toBeDefined();
      if (fixture.expect.remedyResolves === false) return;
      const after = proposeSchedule(applyRemedy(fixture.input, remedy));
      // A remedy for an infeasible schedule has to make it fit; it does not
      // have to make it comfortable, and the cheapest one rarely does.
      expect(after.feasibility.status).not.toBe("infeasible");
      if (fixture.expect.status === "tight") {
        expect(after.feasibility.status).toBe("ok");
      }
    });
  }
});

describe("topics come from the curriculum snapshot, in order (§7.3 step 6)", () => {
  const proposal = proposeSchedule({
    ...base,
    today: d("2026-06-01"),
    weddingDate: d("2026-08-20"),
    sessionCount: 3,
    cadence: { kind: "perWeek", n: 1 },
    earliestStart: d("2026-06-01"),
    bufferDays: 14,
    topics: TOPICS.slice(0, 2),
  });

  it("assigns snapshot topics by order index", () => {
    expect(proposal.slots.map((slot) => slot.topic?.title ?? null)).toEqual([
      "הלכות נידה",
      "טהרה",
      null,
    ]);
  });
});

describe("pinned slots", () => {
  const input: ScheduleInput = {
    ...base,
    today: d("2026-06-01"),
    weddingDate: d("2026-08-20"),
    sessionCount: 3,
    cadence: { kind: "perWeek", n: 1 },
    earliestStart: d("2026-06-01"),
    bufferDays: 14,
    pinned: [{ orderIndex: 3, date: d("2026-08-10") }],
  };

  it("flags a pinned session that falls after the effective deadline", () => {
    const proposal = proposeSchedule(input);
    const last = proposal.slots.at(-1);
    expect(last?.date).toBe("2026-08-10");
    expect(last?.source).toBe("pinned");
    expect(last?.conflicts).toEqual([{ kind: "afterDeadline", days: 4 }]);
    // The conflict is reported on the slot; it does not invent a Feasibility
    // warning, because none of §7.4's four remedies means "unpin it".
    expect(proposal.feasibility.status).toBe("ok");
  });

  it("flags a pinned session that collides with a blackout, and keeps it", () => {
    const proposal = proposeSchedule({
      ...input,
      pinned: [{ orderIndex: 2, date: d("2026-06-10") }],
      blackouts: [
        {
          id: "blk-1",
          startsOn: d("2026-06-10"),
          endsOn: d("2026-06-12"),
          reason: "חופשה",
        },
      ],
    });
    const pinned = proposal.slots.find((slot) => slot.orderIndex === 2);
    expect(pinned?.date).toBe("2026-06-10");
    expect(pinned?.conflicts).toEqual([
      {
        kind: "unavailableDay",
        reason: { kind: "blackout", blackoutId: "blk-1", note: "חופשה" },
      },
    ]);
  });

  it("flags a pinned session on Tisha B'Av without moving it", () => {
    const proposal = proposeSchedule({
      ...input,
      today: d("2026-07-01"),
      earliestStart: d("2026-07-01"),
      pinned: [{ orderIndex: 3, date: d("2026-07-23") }],
    });
    const pinned = proposal.slots.find((slot) => slot.orderIndex === 3);
    expect(pinned?.date).toBe("2026-07-23");
    expect(pinned?.conflicts).toEqual([
      {
        kind: "unavailableDay",
        reason: {
          kind: "fastDay",
          holiday: "Tish'a B'Av",
          severity: "major",
        },
      },
    ]);
  });

  it("steps a proposed session over a day a pinned session already holds", () => {
    const proposal = proposeSchedule({
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-06-29"),
      sessionCount: 3,
      cadence: { kind: "everyNDays", n: 7 },
      earliestStart: d("2026-06-01"),
      bufferDays: 14,
      pinned: [{ orderIndex: 2, date: d("2026-06-08") }],
    });
    expect(proposal.slots.map((slot) => slot.date)).toEqual([
      "2026-06-01",
      "2026-06-08",
      "2026-06-15",
    ]);
    expect(proposal.slots.map((slot) => slot.source)).toEqual([
      "proposed",
      "pinned",
      "proposed",
    ]);
  });
});

describe("a warning cannot be constructed without a remedy (§7.4)", () => {
  // These assertions are checked by `tsc`, not by vitest: if `remedy` ever
  // becomes optional on a non-`ok` variant, the @ts-expect-error comments stop
  // being errors and the typecheck fails. "A warning without a way out is a
  // type error, not a copy review."
  it("is enforced by the type", () => {
    const warned: Feasibility = {
      status: "tight",
      message: "no_slack",
      remedy: { kind: "reduceSessions", to: 3 },
    };
    expect(warned.status).toBe("tight");

    // @ts-expect-error — 'tight' without a remedy is not a Feasibility.
    const tightWithoutRemedy: Feasibility = {
      status: "tight",
      message: "no_slack",
    };
    // @ts-expect-error — neither is 'infeasible' without one.
    const infeasibleWithoutRemedy: Feasibility = {
      status: "infeasible",
      message: "not_enough_available_days",
    };
    expect([tightWithoutRemedy, infeasibleWithoutRemedy]).toHaveLength(2);
  });
});

describe("the buffer (§7.2)", () => {
  it("defaults to 14 days", () => {
    expect(DEFAULT_BUFFER_DAYS).toBe(14);
    expect(effectiveDeadline(d("2026-08-20"))).toBe("2026-08-06");
  });

  it("is per-course and editable", () => {
    expect(effectiveDeadline(d("2026-08-20"), 0)).toBe("2026-08-20");
    expect(effectiveDeadline(d("2026-08-20"), 30)).toBe("2026-07-21");
  });
});

describe("remedies are ranked cheapest-first (§7.4)", () => {
  // Raising the cadence fixes this without costing her anything else, so it is
  // offered even though a later start or a shorter buffer would also work.
  it("prefers a higher cadence to a longer runway", () => {
    const proposal = proposeSchedule({
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-08-20"),
      sessionCount: 14,
      cadence: { kind: "perWeek", n: 1 },
      earliestStart: d("2026-06-15"),
      bufferDays: 14,
    });
    expect(proposal.feasibility.status).toBe("infeasible");
    if (proposal.feasibility.status === "ok") throw new Error("unreachable");
    expect(proposal.feasibility.remedy.kind).toBe("increaseCadence");
  });

  // Cadence is already at the ceiling, so the next cheapest change is to start
  // earlier — before touching the buffer, and never before today.
  it("prefers starting earlier to shortening the buffer", () => {
    const proposal = proposeSchedule({
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-08-20"),
      sessionCount: 40,
      cadence: { kind: "perWeek", n: 7 },
      earliestStart: d("2026-07-15"),
      bufferDays: 14,
    });
    if (proposal.feasibility.status === "ok") throw new Error("unreachable");
    expect(proposal.feasibility.remedy.kind).toBe("startEarlier");
    if (proposal.feasibility.remedy.kind !== "startEarlier") return;
    expect(
      compareDates(proposal.feasibility.remedy.date, d("2026-06-01")),
    ).toBeGreaterThanOrEqual(0);
  });

  // Already daily and already starting today, so the cadence cannot rise and
  // the start cannot move: the buffer is the only lever left above content.
  it("prefers shortening the buffer to dropping sessions", () => {
    const proposal = proposeSchedule({
      ...base,
      today: d("2026-06-01"),
      weddingDate: d("2026-06-18"),
      sessionCount: 6,
      cadence: { kind: "everyNDays", n: 1 },
      earliestStart: d("2026-06-01"),
      bufferDays: 14,
    });
    if (proposal.feasibility.status === "ok") throw new Error("unreachable");
    expect(proposal.feasibility.remedy).toEqual({
      kind: "reduceBuffer",
      days: 11,
    });
  });
});

describe("purity (invariant 4)", () => {
  const input: ScheduleInput = {
    ...base,
    today: d("2026-06-01"),
    weddingDate: d("2026-08-20"),
    sessionCount: 8,
    cadence: { kind: "perWeek", n: 1 },
    earliestStart: d("2026-06-01"),
    bufferDays: 14,
    topics: TOPICS,
  };

  it("returns the same proposal for the same input", () => {
    expect(proposeSchedule(input)).toEqual(proposeSchedule(input));
  });

  it("does not mutate its input", () => {
    const snapshot = JSON.stringify(input);
    proposeSchedule(input);
    expect(JSON.stringify(input)).toBe(snapshot);
  });
});
