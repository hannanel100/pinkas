/**
 * The backward-scheduling engine — SDD §7.
 *
 * PRD §9 calls this "the logic that justifies the system". Sessions are placed
 * **backward from `weddingDate − bufferDays`**, not forward from today, because
 * that anchors the plan on the constraint that cannot move (§7.3).
 *
 * Three things this module refuses to do quietly:
 *
 * * **Skips are output.** Every day the walk steps over is returned with its
 *   reason (§7.6). A silently-skipped Tisha B'Av looks like a bug.
 * * **A warning carries a way out.** `Feasibility` is a union in which the two
 *   non-`ok` variants have a non-optional `Remedy` (§7.4) — "too tight" alone
 *   is a complaint, not help.
 * * **Nothing is written.** Recomputation (§7.5) returns a proposal and the
 *   instructor confirms it; completed and pinned sessions never move, which is
 *   expressed by passing them in as `pinned` slots.
 *
 * Invariant 4: pure. No I/O, no clock — `today` is an input. Invariant 6: topics
 * come from the course's `curriculum_snapshot`, never from the live template.
 */

import {
  addDays,
  calendarUnavailability,
  compareDates,
  dayNumber,
  fromDayNumber,
  type CalendarDate,
  type CalendarUnavailability,
  type Observance,
} from "./hebrew-calendar";

/* ── Input (§7.1, verbatim, plus two documented additions) ────────────────── */

export type Cadence =
  | { readonly kind: "perWeek"; readonly n: number }
  | { readonly kind: "everyNDays"; readonly n: number };

/** A `blackout_date` row. Inclusive of both ends, as the table's check implies. */
export type DateRange = {
  readonly startsOn: CalendarDate;
  readonly endsOn: CalendarDate;
  /** `blackout_date.id`, so the UI can link the skip back to the row. */
  readonly id?: string;
  /** `blackout_date.reason` — instructor-authored, passed through untouched. */
  readonly reason?: string;
};

/**
 * A session that must not move. `kind` records *why*, so the UI can say
 * "already taught" rather than "pinned" — §7.5 treats completed and pinned
 * sessions identically for placement but they are not the same to the reader.
 */
export type PinnedSlot = {
  readonly orderIndex: number;
  readonly date: CalendarDate;
  readonly kind?: "pinned" | "completed";
};

/** One topic from `course.curriculum_snapshot`, in snapshot order (ADR-0004). */
export type ScheduleTopic = {
  readonly id?: string;
  readonly title: string;
};

/**
 * §7.1 gives the first eight fields verbatim. `topics` and `observance` are
 * additions, both optional so the documented shape remains valid input:
 * `topics` because §7.3 step 6 assigns topics from the snapshot and the engine
 * cannot read the database to find them (invariant 4); `observance` because
 * §7.3 step 2 says "as configured" and nothing in the Phase-1 schema stores
 * that configuration yet.
 */
export type ScheduleInput = {
  readonly today: CalendarDate;
  readonly weddingDate: CalendarDate;
  readonly sessionCount: number;
  readonly cadence: Cadence;
  readonly earliestStart: CalendarDate;
  readonly bufferDays: number;
  readonly blackouts: readonly DateRange[];
  readonly pinned: readonly PinnedSlot[];
  readonly topics?: readonly ScheduleTopic[];
  readonly observance?: Observance;
};

/* ── Output ───────────────────────────────────────────────────────────────── */

/**
 * Why a day could not take a session. Calendar reasons come from
 * `hebrew-calendar.ts`; the other two are the engine's own. Blackouts report
 * separately from calendar-derived days because the bride-facing explanation
 * differs: "skipped · unavailable" versus "skipped · Tisha B'Av" (§7.6).
 */
export type UnavailableReason =
  | CalendarUnavailability
  | {
      readonly kind: "blackout";
      readonly blackoutId?: string;
      readonly note?: string;
    }
  | { readonly kind: "occupied"; readonly orderIndex: number };

/** A day the backward walk stepped over. Surfaced, never silent (§7.6). */
export type Skip = {
  readonly date: CalendarDate;
  readonly reason: UnavailableReason;
};

/**
 * Something wrong with a slot that the engine honoured anyway. Only immovable
 * slots can carry one: a pinned session on Tisha B'Av is not skipped — it is
 * kept, and flagged, because the instructor may know something the system does
 * not (§7.5, note c4). It does not change `feasibility`, because none of §7.4's
 * four remedies addresses "unpin it" and inventing one would be dishonest.
 */
export type SlotConflict =
  | { readonly kind: "unavailableDay"; readonly reason: UnavailableReason }
  | { readonly kind: "afterDeadline"; readonly days: number };

export type Slot = {
  /** 1-based, matching `session.order_index`. */
  readonly orderIndex: number;
  readonly date: CalendarDate;
  readonly source: "proposed" | "pinned" | "completed";
  /** From `curriculum_snapshot` in order; `null` when the snapshot is shorter. */
  readonly topic: ScheduleTopic | null;
  readonly conflicts: readonly SlotConflict[];
};

/**
 * Why the schedule is not `ok`, as a stable code.
 *
 * §7.4 types this field `message: string`. It is narrowed to a code union here
 * because product copy is Hebrew and lives in the translation layer (invariant
 * 8) — an English sentence emitted from a pure engine could never reach the
 * screen. A code is assignable to `string`, so callers written against the SDD
 * signature still compile.
 */
export type FeasibilityCode =
  | "deadline_in_the_past"
  | "deadline_before_earliest_start"
  | "not_enough_available_days"
  | "no_slack";

export type Remedy =
  | {
      readonly kind: "increaseCadence";
      readonly perWeek: number;
      readonly forWeeks: number;
    }
  | { readonly kind: "startEarlier"; readonly date: CalendarDate }
  | { readonly kind: "reduceBuffer"; readonly days: number }
  | { readonly kind: "reduceSessions"; readonly to: number };

export type Feasibility =
  | { readonly status: "ok" }
  | {
      readonly status: "tight";
      readonly message: FeasibilityCode;
      readonly remedy: Remedy;
    }
  | {
      readonly status: "infeasible";
      readonly message: FeasibilityCode;
      readonly remedy: Remedy;
    };

export type ScheduleProposal = {
  readonly slots: readonly Slot[];
  readonly skips: readonly Skip[];
  readonly feasibility: Feasibility;
};

/* ── Constants ────────────────────────────────────────────────────────────── */

/** `instructor.default_buffer_days` / `course.buffer_days` (§7.2). */
export const DEFAULT_BUFFER_DAYS = 14;

/** The wedding is not the deadline; the immersion is (§7.2). */
export function effectiveDeadline(
  weddingDate: CalendarDate,
  bufferDays: number = DEFAULT_BUFFER_DAYS,
): CalendarDate {
  return addDays(weddingDate, -Math.max(0, Math.trunc(bufferDays)));
}

/** Days between sessions. `perWeek` may be fractional — 2/week is every 3½ days. */
function intervalDays(cadence: Cadence): number {
  const n = Number.isFinite(cadence.n) ? cadence.n : 1;
  if (cadence.kind === "perWeek") {
    return n > 0 ? 7 / n : 7;
  }
  return n > 0 ? n : 1;
}

/* ── Placement ────────────────────────────────────────────────────────────── */

type Context = {
  readonly todayRd: number;
  readonly weddingRd: number;
  readonly earliestStartRd: number;
  readonly blackouts: readonly DateRange[];
  readonly observance: Observance | undefined;
  readonly topics: readonly ScheduleTopic[];
  /** Memo across every placement attempt in one call; inputs never change. */
  readonly unavailability: Map<number, UnavailableReason | null>;
};

type Attempt = {
  readonly slots: Slot[];
  readonly skips: Skip[];
  readonly placedAll: boolean;
  readonly hasSlack: boolean;
};

type AttemptParams = {
  readonly deadlineRd: number;
  readonly floorRd: number;
  readonly sessionCount: number;
  readonly interval: number;
  readonly pinned: readonly PinnedSlot[];
};

function blackoutOn(
  ctx: Context,
  date: CalendarDate,
): UnavailableReason | null {
  for (const range of ctx.blackouts) {
    if (
      compareDates(date, range.startsOn) >= 0 &&
      compareDates(date, range.endsOn) <= 0
    ) {
      return {
        kind: "blackout",
        ...(range.id === undefined ? {} : { blackoutId: range.id }),
        ...(range.reason === undefined ? {} : { note: range.reason }),
      };
    }
  }
  return null;
}

/**
 * The calendar first, then this tenant's blackouts: a day that is both Tisha
 * B'Av and inside a declared holiday reports Tisha B'Av, which is the more
 * explanatory of the two (§7.6).
 */
function unavailableOn(ctx: Context, rd: number): UnavailableReason | null {
  const cached = ctx.unavailability.get(rd);
  if (cached !== undefined) return cached;
  const date = fromDayNumber(rd);
  const reason: UnavailableReason | null =
    calendarUnavailability(date, ctx.observance) ?? blackoutOn(ctx, date);
  ctx.unavailability.set(rd, reason);
  return reason;
}

function topicFor(ctx: Context, orderIndex: number): ScheduleTopic | null {
  return ctx.topics[orderIndex - 1] ?? null;
}

/**
 * One backward walk. Extracted because the remedy search (§7.4) re-runs exactly
 * this computation against modified inputs — "the same computation, not a
 * second one" (§7.4).
 */
function walkBackward(ctx: Context, params: AttemptParams): Attempt {
  const { deadlineRd, floorRd, sessionCount, interval } = params;

  const pinnedByIndex = new Map<number, PinnedSlot>();
  const pinnedDates = new Map<number, number>(); // rd → orderIndex
  for (const slot of params.pinned) {
    if (slot.orderIndex >= 1 && slot.orderIndex <= sessionCount) {
      pinnedByIndex.set(slot.orderIndex, slot);
      pinnedDates.set(dayNumber(slot.date), slot.orderIndex);
    }
  }

  const slots: Slot[] = [];
  const skips: Skip[] = [];
  let placedAll = true;
  let earliestProposedRd: number | null = null;
  let nextPlacedRd = Number.POSITIVE_INFINITY;
  let ideal = deadlineRd;

  for (let orderIndex = sessionCount; orderIndex >= 1; orderIndex--) {
    const pin = pinnedByIndex.get(orderIndex);

    if (pin) {
      const rd = dayNumber(pin.date);
      const conflicts: SlotConflict[] = [];
      const reason = unavailableOn(ctx, rd);
      if (reason) conflicts.push({ kind: "unavailableDay", reason });
      if (rd > deadlineRd) {
        conflicts.push({ kind: "afterDeadline", days: rd - deadlineRd });
      }
      slots.push({
        orderIndex,
        date: pin.date,
        source: pin.kind === "completed" ? "completed" : "pinned",
        topic: topicFor(ctx, orderIndex),
        conflicts,
      });
      nextPlacedRd = rd;
      ideal = rd - interval;
      continue;
    }

    let candidate = Math.round(ideal);
    if (candidate >= nextPlacedRd) candidate = nextPlacedRd - 1;

    let placedRd: number | null = null;
    while (candidate >= floorRd) {
      const occupiedBy = pinnedDates.get(candidate);
      const reason: UnavailableReason | null =
        occupiedBy === undefined
          ? unavailableOn(ctx, candidate)
          : { kind: "occupied", orderIndex: occupiedBy };
      if (reason === null) {
        placedRd = candidate;
        break;
      }
      skips.push({ date: fromDayNumber(candidate), reason });
      candidate -= 1;
    }

    if (placedRd === null) {
      placedAll = false;
      break;
    }

    slots.push({
      orderIndex,
      date: fromDayNumber(placedRd),
      source: "proposed",
      topic: topicFor(ctx, orderIndex),
      conflicts: [],
    });
    nextPlacedRd = placedRd;
    earliestProposedRd = placedRd;
    ideal = placedRd - interval;
  }

  slots.reverse();
  skips.reverse();

  // Slack: could one more session have been placed before the first proposed
  // one? A schedule with no room left is "tight" — it fits, but any cancelled
  // session breaks it, and §7.4 says she should be told before that happens.
  let hasSlack = true;
  if (placedAll && earliestProposedRd !== null) {
    hasSlack = false;
    let probe = Math.min(
      Math.round(earliestProposedRd - interval),
      earliestProposedRd - 1,
    );
    while (probe >= floorRd) {
      if (!pinnedDates.has(probe) && unavailableOn(ctx, probe) === null) {
        hasSlack = true;
        break;
      }
      probe -= 1;
    }
  }

  return {
    slots,
    skips,
    placedAll,
    hasSlack,
  };
}

/* ── Remedies (§7.4) ──────────────────────────────────────────────────────── */

type RemedyGoal = "fit" | "slack";

function satisfies(attempt: Attempt, goal: RemedyGoal): boolean {
  return goal === "fit"
    ? attempt.placedAll
    : attempt.placedAll && attempt.hasSlack;
}

function currentPerWeek(cadence: Cadence): number {
  return cadence.kind === "perWeek" ? cadence.n : 7 / intervalDays(cadence);
}

const MAX_PER_WEEK = 7;

/**
 * Cheapest first: raise the cadence before shortening the buffer, and shorten
 * the buffer before dropping content (§7.4). The order of the four blocks below
 * *is* that ranking, and each is only offered if it actually resolves the
 * problem — a remedy that does not work is another warning with no way out.
 */
function findRemedy(
  ctx: Context,
  input: ScheduleInput,
  base: AttemptParams,
  goal: RemedyGoal,
): Remedy {
  const weeksAvailable = Math.max(
    1,
    Math.ceil((base.deadlineRd - base.floorRd + 1) / 7),
  );

  // 1. Raise the cadence — costs her nothing but calendar density.
  const from = Math.max(1, Math.floor(currentPerWeek(input.cadence)));
  for (let perWeek = from + 1; perWeek <= MAX_PER_WEEK; perWeek++) {
    const attempt = walkBackward(ctx, { ...base, interval: 7 / perWeek });
    if (satisfies(attempt, goal)) {
      return { kind: "increaseCadence", perWeek, forWeeks: weeksAvailable };
    }
  }

  // 2. Start earlier — only meaningful if the start is genuinely movable, and
  //    never into the past. Latest workable start, so she loses the least.
  if (base.floorRd > ctx.todayRd) {
    for (let startRd = base.floorRd - 1; startRd >= ctx.todayRd; startRd--) {
      const attempt = walkBackward(ctx, { ...base, floorRd: startRd });
      if (satisfies(attempt, goal)) {
        return { kind: "startEarlier", date: fromDayNumber(startRd) };
      }
    }
  }

  // 3. Shorten the buffer — this eats into the days before the immersion, so it
  //    is a real cost and ranks below the two above (§7.2).
  const buffer = Math.max(0, Math.trunc(input.bufferDays));
  for (let days = buffer - 1; days >= 0; days--) {
    const attempt = walkBackward(ctx, {
      ...base,
      deadlineRd: ctx.weddingRd - days,
    });
    if (satisfies(attempt, goal)) {
      return { kind: "reduceBuffer", days };
    }
  }

  // 4. Drop content — last, because it is the only remedy that changes what the
  //    bride is taught. The most sessions that still fit, so she loses least.
  for (let to = base.sessionCount - 1; to >= 1; to--) {
    const attempt = walkBackward(ctx, {
      ...base,
      sessionCount: to,
      pinned: base.pinned.filter((slot) => slot.orderIndex <= to),
    });
    if (satisfies(attempt, goal)) {
      return { kind: "reduceSessions", to };
    }
  }

  // The one place the ranking is overridden, and deliberately. If not even a
  // single session fits, the deadline has passed or is about to: "teach nothing"
  // is not help, and dropping the buffer is the only change that creates any day
  // at all. Only when there is no buffer left to drop is `reduceSessions: 0` the
  // truthful last word — at that point nothing can be scheduled before the
  // wedding, and the product should say so rather than suggest a fix.
  return buffer > 0
    ? { kind: "reduceBuffer", days: 0 }
    : { kind: "reduceSessions", to: 0 };
}

/* ── Entry point ──────────────────────────────────────────────────────────── */

/**
 * Propose a schedule. Pure: same input, same output, no clock, no database.
 *
 * Recomputation (§7.5) is this same function — pass completed sessions as
 * `pinned` with `kind: "completed"` and everything else reflows around them.
 * The result is a proposal; writing it is the instructor's decision.
 */
export function proposeSchedule(input: ScheduleInput): ScheduleProposal {
  const sessionCount = Math.max(0, Math.trunc(input.sessionCount));
  const bufferDays = Math.max(0, Math.trunc(input.bufferDays));
  const deadline = effectiveDeadline(input.weddingDate, bufferDays);

  const ctx: Context = {
    todayRd: dayNumber(input.today),
    weddingRd: dayNumber(input.weddingDate),
    earliestStartRd: dayNumber(input.earliestStart),
    blackouts: input.blackouts,
    observance: input.observance,
    topics: input.topics ?? [],
    unavailability: new Map(),
  };

  const params: AttemptParams = {
    deadlineRd: dayNumber(deadline),
    // Nothing is proposed into the past, whatever `earliestStart` says. Pinned
    // and completed slots are exempt — they already happened.
    floorRd: Math.max(ctx.earliestStartRd, ctx.todayRd),
    sessionCount,
    interval: intervalDays(input.cadence),
    pinned: input.pinned,
  };

  const attempt = walkBackward(ctx, params);

  let feasibility: Feasibility;
  if (!attempt.placedAll) {
    const message: FeasibilityCode =
      params.deadlineRd < ctx.todayRd
        ? "deadline_in_the_past"
        : params.deadlineRd < ctx.earliestStartRd
          ? "deadline_before_earliest_start"
          : "not_enough_available_days";
    feasibility = {
      status: "infeasible",
      message,
      remedy: findRemedy(ctx, input, params, "fit"),
    };
  } else if (!attempt.hasSlack) {
    feasibility = {
      status: "tight",
      message: "no_slack",
      remedy: findRemedy(ctx, input, params, "slack"),
    };
  } else {
    feasibility = { status: "ok" };
  }

  return { slots: attempt.slots, skips: attempt.skips, feasibility };
}
