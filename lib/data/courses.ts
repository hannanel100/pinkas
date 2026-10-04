import "server-only";

import {
  tryParseCalendarDate,
  type CalendarDate,
} from "@/lib/domain/hebrew-calendar";
import type { Observance } from "@/lib/domain/hebrew-calendar";
import {
  effectiveDeadline,
  proposeSchedule,
  type Cadence,
  type DateRange,
  type PinnedSlot,
  type ScheduleProposal,
} from "@/lib/domain/scheduling";

import {
  defineMutation,
  defineRead,
  notOk,
  ok,
  type FormResult,
  type NoSubjectContext,
  type Result,
} from "./context";
import {
  jerusalemDateOf,
  jerusalemTimestampLiteral,
  parseLocalTime,
} from "./internal/clock";
import { DataAccessError, fail } from "./internal/errors";
import { newUuid, parseUuid, type Uuid } from "./internal/ids";
import {
  SNAPSHOT_VERSION,
  parseCurriculumSnapshot,
  type CurriculumSnapshotV1,
} from "./internal/snapshot";
import {
  asRow,
  asRows,
  boolField,
  embeddedMany,
  embeddedOne,
  enumField,
  intField,
  optionalDateField,
  optionalDecimalField,
  optionalStringField,
  parseDecimal,
  stringField,
  uuidField,
  type Row,
} from "./internal/values";

/**
 * Courses — creation with a curriculum snapshot (ADR-0004, invariant 6), and
 * the scheduling round trip of plate 03 (SDD §7, §12.3).
 *
 * The algorithm is not here. `recomputeSchedule` gathers inputs and calls
 * `proposeSchedule()` from `lib/domain/scheduling.ts` with `today` injected;
 * it writes nothing (§7.5 — "the algorithm proposes, it does not decide").
 * `confirmSchedule` writes what she confirmed.
 */

export type { CurriculumSnapshotV1, SnapshotTopic } from "./internal/snapshot";

/* ── createCourse ────────────────────────────────────────────────────────── */

/** No `id`: the database generates it (security review of #55). */
export type NewCourse = {
  readonly brideId: string;
  readonly curriculumId: string;
  /** Defaults to `instructor.default_buffer_days` (§7.2). */
  readonly bufferDays?: number;
  /** Decimal string; defaults to the curriculum's, then her `default_price` (A4). */
  readonly agreedPrice?: string | null;
  readonly startDate?: CalendarDate | null;
  readonly id?: never;
  readonly tenantId?: never;
};

export type NewCourseField = "brideId" | "curriculumId" | "bufferDays" | "agreedPrice" | "startDate";

const CREATE = "course.create";

/**
 * Creates a `draft` course for one of her brides, freezing the curriculum
 * into `curriculum_snapshot`. `curriculum_id` is kept for provenance only.
 * Sessions are created by `confirmSchedule`, after she has seen the proposal.
 */
export const createCourse = defineMutation(
  { resource: "course", action: "create", subjects: "per-bride" },
  async (ctx, input: NewCourse): Promise<FormResult<{ id: Uuid }, NewCourseField>> => {
    const invalid: NewCourseField[] = [];
    const brideId = parseUuid(input.brideId);
    const curriculumId = parseUuid(input.curriculumId);
    if (!brideId) invalid.push("brideId");
    if (!curriculumId) invalid.push("curriculumId");
    const buffer = input.bufferDays;
    if (buffer !== undefined && (!Number.isInteger(buffer) || buffer < 0 || buffer > 120)) {
      invalid.push("bufferDays");
    }
    const price =
      input.agreedPrice === undefined || input.agreedPrice === null
        ? null
        : parseDecimal(input.agreedPrice);
    if (input.agreedPrice != null && price === null) invalid.push("agreedPrice");
    const startDate =
      input.startDate == null ? null : tryParseCalendarDate(String(input.startDate));
    if (input.startDate != null && startDate === null) invalid.push("startDate");
    if (invalid.length > 0 || !brideId || !curriculumId) return { ok: false, invalid };

    const [cur, bride] = await Promise.all([
      ctx.db
        .from("curriculum")
        .select(
          "id, name, description, default_session_count, default_price::text, " +
            "curriculum_topic(id, order_index, title, description, estimated_minutes, deleted_at)",
        )
        .eq("id", curriculumId)
        .eq("tenant_id", ctx.tenantId)
        .is("deleted_at", null)
        .maybeSingle(),
      ctx.db
        .from("bride")
        .select("id, wedding_date, instructor!inner(default_buffer_days, default_price::text)")
        .eq("id", brideId)
        .eq("tenant_id", ctx.tenantId)
        .is("deleted_at", null)
        .maybeSingle(),
    ]);
    if (cur.error) fail(`${CREATE}.curriculum`, cur.error);
    if (bride.error) fail(`${CREATE}.bride`, bride.error);
    if (!cur.data) return { ok: false, invalid: ["curriculumId"] };
    if (!bride.data) return { ok: false, invalid: ["brideId"] };

    const c = asRow(CREATE, cur.data);
    const b = asRow(CREATE, bride.data);
    const instructor = embeddedOne(CREATE, b, "instructor");

    const snapshot: CurriculumSnapshotV1 = {
      curriculum: {
        id: uuidField(CREATE, c, "id"),
        name: stringField(CREATE, c, "name"),
        description: optionalStringField(CREATE, c, "description"),
        defaultSessionCount: intField(CREATE, c, "default_session_count"),
      },
      topics: embeddedMany(CREATE, c, "curriculum_topic")
        .filter((t) => t.deleted_at === null)
        .map((t) => ({
          id: uuidField(CREATE, t, "id"),
          orderIndex: intField(CREATE, t, "order_index"),
          title: stringField(CREATE, t, "title"),
          description: optionalStringField(CREATE, t, "description"),
          estimatedMinutes:
            t.estimated_minutes === null ? null : intField(CREATE, t, "estimated_minutes"),
        }))
        .sort((x, y) => x.orderIndex - y.orderIndex),
    };

    const bufferDays = buffer ?? intField(CREATE, instructor, "default_buffer_days");
    const weddingDate = optionalDateField(CREATE, b, "wedding_date");
    const agreedPrice =
      price ??
      optionalDecimalField(CREATE, c, "default_price") ??
      optionalDecimalField(CREATE, instructor, "default_price");

    const { data, error } = await ctx.db
      .from("course")
      .insert({
        tenant_id: ctx.tenantId,
        bride_id: brideId,
        curriculum_id: curriculumId,
        curriculum_snapshot: snapshot,
        snapshot_version: SNAPSHOT_VERSION,
        start_date: startDate,
        target_end_date: weddingDate ? effectiveDeadline(weddingDate, bufferDays) : null,
        buffer_days: bufferDays,
        agreed_price: agreedPrice,
        status: "draft",
      })
      .select("id")
      .single();
    if (error) fail(CREATE, error);
    ctx.subject(brideId);
    return ok({ id: uuidField(CREATE, asRow(CREATE, data), "id") });
  },
);

/* ── Shared course read for scheduling ───────────────────────────────────── */

const COURSE_STATUSES = ["draft", "active", "completed", "cancelled"] as const;
const SESSION_STATUSES = ["planned", "done", "cancelled", "rescheduled"] as const;

type ScheduleSession = {
  readonly id: Uuid;
  readonly orderIndex: number;
  readonly scheduledAt: string | null;
  readonly status: (typeof SESSION_STATUSES)[number];
  readonly isPinned: boolean;
  readonly location: string | null;
  readonly durationMinutes: number;
};

type ScheduleCourse = {
  readonly id: Uuid;
  readonly brideId: Uuid;
  readonly status: (typeof COURSE_STATUSES)[number];
  readonly startDate: CalendarDate | null;
  readonly bufferDays: number;
  readonly weddingDate: CalendarDate | null;
  readonly snapshot: CurriculumSnapshotV1;
  readonly sessions: readonly ScheduleSession[];
};

async function loadCourse(
  db: NoSubjectContext["db"],
  tenantId: Uuid,
  courseId: Uuid,
): Promise<ScheduleCourse | null> {
  const OP = "course.load";
  const { data, error } = await db
    .from("course")
    .select(
      "id, status, start_date, buffer_days, snapshot_version, curriculum_snapshot, " +
        "bride!inner(id, wedding_date, deleted_at), " +
        "session(id, order_index, scheduled_at, status, is_pinned, location, duration_minutes, deleted_at)",
    )
    .eq("id", courseId)
    .eq("tenant_id", tenantId)
    .is("deleted_at", null)
    .maybeSingle();
  if (error) fail(OP, error);
  if (!data) return null;
  const row = asRow(OP, data);
  const bride = embeddedOne(OP, row, "bride");
  if (bride.deleted_at !== null) return null;
  return {
    id: uuidField(OP, row, "id"),
    brideId: uuidField(OP, bride, "id"),
    status: enumField(OP, row, "status", COURSE_STATUSES),
    startDate: optionalDateField(OP, row, "start_date"),
    bufferDays: intField(OP, row, "buffer_days"),
    weddingDate: optionalDateField(OP, bride, "wedding_date"),
    snapshot: parseCurriculumSnapshot(
      intField(OP, row, "snapshot_version"),
      row.curriculum_snapshot,
    ),
    sessions: embeddedMany(OP, row, "session")
      .filter((s: Row) => s.deleted_at === null)
      .map((s) => ({
        id: uuidField(OP, s, "id"),
        orderIndex: intField(OP, s, "order_index"),
        scheduledAt: optionalStringField(OP, s, "scheduled_at"),
        status: enumField(OP, s, "status", SESSION_STATUSES),
        isPinned: boolField(OP, s, "is_pinned"),
        location: optionalStringField(OP, s, "location"),
        durationMinutes: intField(OP, s, "duration_minutes"),
      })),
  };
}

/** The session currently standing for each order index: done first, else planned. */
function currentByIndex(sessions: readonly ScheduleSession[]): Map<number, ScheduleSession> {
  const map = new Map<number, ScheduleSession>();
  for (const s of sessions) {
    if (s.status !== "done" && s.status !== "planned") continue;
    const prev = map.get(s.orderIndex);
    if (!prev || (prev.status === "planned" && s.status === "done")) map.set(s.orderIndex, s);
  }
  return map;
}

function sessionCountOf(course: ScheduleCourse): number {
  const indices = [...currentByIndex(course.sessions).keys()];
  return Math.max(course.snapshot.curriculum.defaultSessionCount, ...indices);
}

/* ── recomputeSchedule ───────────────────────────────────────────────────── */

export type ScheduleOptions = {
  readonly cadence: Cadence;
  /** Defaults to the course's `start_date`, then today. */
  readonly earliestStart?: CalendarDate;
  readonly observance?: Observance;
};

function validCadence(c: Cadence | undefined): c is Cadence {
  if (!c || typeof c.n !== "number" || !Number.isFinite(c.n) || c.n <= 0) return false;
  if (c.kind === "perWeek") return c.n <= 7;
  if (c.kind === "everyNDays") return c.n <= 60;
  return false;
}

export type ScheduleProposalView = {
  readonly courseId: Uuid;
  readonly weddingDate: CalendarDate;
  readonly bufferDays: number;
  readonly proposal: ScheduleProposal;
};

/**
 * A proposal for the course's remaining sessions (C5, §7.5). Completed and
 * pinned sessions are passed to the engine as immovable; nothing is written.
 * `{ ok: false }` for a course that is not hers, or whose bride has no wedding
 * date yet (there is no deadline to schedule backward from).
 */
export const recomputeSchedule = defineRead(
  { resource: "schedule", subjects: "per-bride" },
  async (
    ctx,
    courseId: string,
    options: ScheduleOptions,
  ): Promise<Result<ScheduleProposalView>> => {
    const id = parseUuid(courseId);
    if (!id || !validCadence(options?.cadence)) return notOk;
    const course = await loadCourse(ctx.db, ctx.tenantId, id);
    if (!course || !course.weddingDate) return notOk;

    const OP = "blackout_date.list";
    const { data, error } = await ctx.db
      .from("blackout_date")
      .select("id, starts_on, ends_on, reason")
      .eq("tenant_id", ctx.tenantId)
      .is("deleted_at", null);
    if (error) fail(OP, error);
    const blackouts: DateRange[] = asRows(OP, data).map((b) => {
      const startsOn = optionalDateField(OP, b, "starts_on");
      const endsOn = optionalDateField(OP, b, "ends_on");
      if (!startsOn || !endsOn) throw new DataAccessError(OP, "shape");
      const reason = optionalStringField(OP, b, "reason");
      return { id: uuidField(OP, b, "id"), startsOn, endsOn, ...(reason ? { reason } : {}) };
    });

    const pinned: PinnedSlot[] = [];
    for (const s of currentByIndex(course.sessions).values()) {
      if (s.scheduledAt === null) continue;
      if (s.status === "done") {
        pinned.push({ orderIndex: s.orderIndex, date: jerusalemDateOf(s.scheduledAt), kind: "completed" });
      } else if (s.isPinned) {
        pinned.push({ orderIndex: s.orderIndex, date: jerusalemDateOf(s.scheduledAt), kind: "pinned" });
      }
    }

    const earliest =
      options.earliestStart && tryParseCalendarDate(options.earliestStart)
        ? options.earliestStart
        : (course.startDate ?? ctx.today);

    const proposal = proposeSchedule({
      today: ctx.today,
      weddingDate: course.weddingDate,
      sessionCount: sessionCountOf(course),
      cadence: options.cadence,
      earliestStart: earliest,
      bufferDays: course.bufferDays,
      blackouts,
      pinned,
      topics: course.snapshot.topics.map((t) => ({ id: t.id, title: t.title })),
      ...(options.observance ? { observance: options.observance } : {}),
    });

    ctx.subject(course.brideId);
    return ok({
      courseId: course.id,
      weddingDate: course.weddingDate,
      bufferDays: course.bufferDays,
      proposal,
    });
  },
);

/* ── confirmSchedule ─────────────────────────────────────────────────────── */

export type ConfirmScheduleInput = {
  readonly courseId: string;
  /** The proposed slots she confirmed. Pinned and completed slots are ignored. */
  readonly slots: readonly { readonly orderIndex: number; readonly date: CalendarDate }[];
  /** Local time of day in Asia/Jerusalem, `HH:MM`. */
  readonly time: string;
  readonly location?: string | null;
  readonly durationMinutes?: number;
};

const CONFIRM = "session.confirm";

/**
 * Writes the confirmed proposal in one statement: each slot either moves the
 * planned, unpinned session already standing at that order index, or creates
 * one. Completed and pinned sessions are never touched (§7.5). A `draft`
 * course becomes `active`.
 *
 * New session ids are generated here, server-side, never taken from input;
 * existing ids come from her own rows as just read. Idempotent on retry: a
 * second call finds the sessions the first created and moves them instead.
 */
export const confirmSchedule = defineMutation(
  { resource: "schedule", action: "update", subjects: "per-bride" },
  async (ctx, input: ConfirmScheduleInput): Promise<Result<{ sessionIds: Uuid[] }>> => {
    const courseId = parseUuid(input.courseId);
    const time = parseLocalTime(input.time);
    if (!courseId || !time || !Array.isArray(input.slots) || input.slots.length > 200) {
      return notOk;
    }
    const duration = input.durationMinutes;
    if (duration !== undefined && (!Number.isInteger(duration) || duration <= 0 || duration > 600)) {
      return notOk;
    }
    const seen = new Set<number>();
    const slots: { orderIndex: number; date: CalendarDate }[] = [];
    for (const slot of input.slots) {
      const date = tryParseCalendarDate(String(slot?.date));
      const idx = slot?.orderIndex;
      if (!date || !Number.isInteger(idx) || idx < 1 || idx > 200 || seen.has(idx)) return notOk;
      seen.add(idx);
      slots.push({ orderIndex: idx, date });
    }

    const course = await loadCourse(ctx.db, ctx.tenantId, courseId);
    if (!course || (course.status !== "draft" && course.status !== "active")) return notOk;

    const current = currentByIndex(course.sessions);
    const location =
      input.location === undefined ? undefined : (input.location?.trim() || null);
    const rows = [];
    for (const slot of slots) {
      const existing = current.get(slot.orderIndex);
      if (existing && (existing.status === "done" || existing.isPinned)) continue;
      rows.push({
        id: existing?.id ?? newUuid(),
        tenant_id: ctx.tenantId,
        course_id: course.id,
        order_index: slot.orderIndex,
        scheduled_at: jerusalemTimestampLiteral(slot.date, time),
        status: "planned",
        location: location === undefined ? (existing?.location ?? null) : location,
        duration_minutes: duration ?? existing?.durationMinutes ?? 60,
      });
    }

    if (rows.length > 0) {
      const { error } = await ctx.db.from("session").upsert(rows, { onConflict: "id" });
      if (error) fail(CONFIRM, error);
    }
    if (course.status === "draft") {
      const { error } = await ctx.db
        .from("course")
        .update({ status: "active" })
        .eq("id", course.id)
        .eq("tenant_id", ctx.tenantId)
        .eq("status", "draft");
      if (error) fail("course.activate", error);
    }

    ctx.subject(course.brideId);
    return ok({ sessionIds: rows.map((r) => r.id) });
  },
);
