import "server-only";

import { tryParseCalendarDate, type CalendarDate } from "@/lib/domain/hebrew-calendar";

import { defineMutation, defineRead, ok, type FormResult } from "./context";
import { fail } from "./internal/errors";
import { parseUuid, type Uuid } from "./internal/ids";
import { normalisePhoneE164 } from "./internal/phone";
import { readRecords, type SessionRecord } from "./internal/records";
import {
  asRow,
  asRows,
  boolField,
  currencyField,
  embeddedMany,
  embeddedOne,
  enumField,
  intField,
  optionalDateField,
  optionalDecimalField,
  optionalStringField,
  optionalUuidField,
  stringField,
  uuidField,
  type Money,
  type Row,
} from "./internal/values";

/**
 * Brides — the list, the card (plate 02), and creation. SDD §3.4, §12.2.
 *
 * Every query below carries `tenant_id = ctx.tenantId` as well as being held
 * to it by RLS: both must fail before data leaks (SDD §4.3). Columns are named
 * explicitly, never `*` — in particular `portal_token_hash` is never selected
 * on this path.
 */

export const BRIDE_STATUSES = ["lead", "active", "completed", "paused", "cancelled"] as const;
export type BrideStatus = (typeof BRIDE_STATUSES)[number];

export const SESSION_STATUSES = ["planned", "done", "cancelled", "rescheduled"] as const;
export type SessionStatus = (typeof SESSION_STATUSES)[number];

export const COURSE_STATUSES = ["draft", "active", "completed", "cancelled"] as const;
export type CourseStatus = (typeof COURSE_STATUSES)[number];

const PAYMENT_METHODS = ["cash", "bit", "paybox", "transfer", "check", "other"] as const;
const PAYERS = ["bride", "family", "religious_council", "other"] as const;
const CALENDAR_SYSTEMS = ["gregorian", "hebrew"] as const;

/* ── listBrides ──────────────────────────────────────────────────────────── */

export type BrideSummary = {
  readonly id: Uuid;
  readonly firstName: string;
  readonly lastName: string | null;
  /** E.164. */
  readonly phone: string | null;
  readonly weddingDate: CalendarDate | null;
  readonly status: BrideStatus;
};

const LIST = "bride.list";

/** Her brides, soonest wedding first. Logs one row per bride listed. */
export const listBrides = defineRead(
  { resource: "bride", subjects: "per-bride" },
  async (
    ctx,
    filter: { readonly statuses?: readonly BrideStatus[] } = {},
  ): Promise<BrideSummary[]> => {
    let query = ctx.db
      .from("bride")
      .select("id, first_name, last_name, phone, wedding_date, status")
      .eq("tenant_id", ctx.tenantId)
      .is("deleted_at", null);
    const statuses = (filter.statuses ?? []).filter((s) =>
      (BRIDE_STATUSES as readonly string[]).includes(s),
    );
    if (statuses.length > 0) query = query.in("status", statuses);
    const { data, error } = await query
      .order("wedding_date", { ascending: true, nullsFirst: false })
      .order("id");
    if (error) fail(LIST, error);

    const brides = asRows(LIST, data).map(
      (row): BrideSummary => ({
        id: uuidField(LIST, row, "id"),
        firstName: stringField(LIST, row, "first_name"),
        lastName: optionalStringField(LIST, row, "last_name"),
        phone: optionalStringField(LIST, row, "phone"),
        weddingDate: optionalDateField(LIST, row, "wedding_date"),
        status: enumField(LIST, row, "status", BRIDE_STATUSES),
      }),
    );
    ctx.subject(...brides.map((b) => b.id));
    return brides;
  },
);

/* ── getBrideCard ────────────────────────────────────────────────────────── */

export type CardSession = {
  readonly id: Uuid;
  readonly orderIndex: number;
  /** ISO 8601 instant; `null` = "טרם נקבע". */
  readonly scheduledAt: string | null;
  readonly durationMinutes: number;
  readonly location: string | null;
  /** Cancelled sessions stay on the timeline (note b4). */
  readonly status: SessionStatus;
  readonly isPinned: boolean;
  readonly rescheduledFromSessionId: Uuid | null;
  /** The private record, if one exists. */
  readonly record: SessionRecord | null;
};

export type CardPayment = {
  readonly id: Uuid;
  readonly amount: Money;
  readonly method: (typeof PAYMENT_METHODS)[number];
  readonly payer: (typeof PAYERS)[number];
  readonly paidAt: CalendarDate;
  readonly receiptNumber: string | null;
};

export type CardCourse = {
  readonly id: Uuid;
  readonly status: CourseStatus;
  readonly startDate: CalendarDate | null;
  /** The effective deadline (§7.2). */
  readonly targetEndDate: CalendarDate | null;
  readonly bufferDays: number;
  /** In the instructor's currency — `course.agreed_price` carries none. */
  readonly agreedPrice: Money | null;
  /** The frozen curriculum (ADR-0004), as stored. Parse with `courses.ts`. */
  readonly curriculumSnapshot: unknown;
  readonly sessions: readonly CardSession[];
  readonly payments: readonly CardPayment[];
};

export type BrideCard = {
  readonly id: Uuid;
  readonly firstName: string;
  readonly lastName: string | null;
  readonly phone: string | null;
  readonly city: string | null;
  readonly groomName: string | null;
  readonly weddingDate: CalendarDate | null;
  readonly weddingDateSource: (typeof CALENDAR_SYSTEMS)[number];
  readonly referralSource: string | null;
  readonly status: BrideStatus;
  /** Shown to the bride as a promise (§6.2); the token itself is never here. */
  readonly portalExpiresAt: string | null;
  readonly currency: string;
  readonly courses: readonly CardCourse[];
};

const CARD = "bride.card";

const CARD_SELECT = `
  id, first_name, last_name, phone, city, groom_name, wedding_date,
  wedding_date_source, referral_source, status, portal_expires_at,
  instructor!inner(currency),
  course(
    id, status, start_date, target_end_date, buffer_days,
    agreed_price::text, curriculum_snapshot, deleted_at,
    session(id, order_index, scheduled_at, duration_minutes, location, status,
            is_pinned, rescheduled_from_session_id, deleted_at),
    payment(id, amount::text, currency, method, payer, paid_at, receipt_number, deleted_at)
  )`;

/**
 * Plate 02 in one call: the bride, her courses with every session and
 * payment, and the private records — the screen opened sixty seconds before
 * every session.
 *
 * Two kinds of `access_log` row share this call's request id: `bride_card`,
 * written here, and `session_record`, written in-database by the audited
 * reader if any record was disclosed. The log records what was disclosed, not
 * which function ran.
 *
 * `null` when the id is not one of her brides — "not found" and "another
 * tenant's" are the same answer.
 */
export const getBrideCard = defineRead(
  { resource: "bride_card", subjects: "per-bride" },
  async (ctx, brideId: string): Promise<BrideCard | null> => {
    const id = parseUuid(brideId);
    if (!id) return null;

    const { data, error } = await ctx.db
      .from("bride")
      .select(CARD_SELECT)
      .eq("id", id)
      .eq("tenant_id", ctx.tenantId)
      .is("deleted_at", null)
      .maybeSingle();
    if (error) fail(CARD, error);
    if (!data) return null;

    const row = asRow(CARD, data);
    const currency = currencyField(CARD, embeddedOne(CARD, row, "instructor"), "currency");
    const live = (rows: readonly Row[]) => rows.filter((r) => r.deleted_at === null);

    const courses = live(embeddedMany(CARD, row, "course")).map((c) => ({
      row: c,
      sessions: live(embeddedMany(CARD, c, "session")),
      payments: live(embeddedMany(CARD, c, "payment")),
    }));

    const sessionIds = courses.flatMap((c) => c.sessions.map((s) => uuidField(CARD, s, "id")));
    const records = new Map(
      (await readRecords(ctx, sessionIds)).map((r) => [r.sessionId, r] as const),
    );

    const card: BrideCard = {
      id: uuidField(CARD, row, "id"),
      firstName: stringField(CARD, row, "first_name"),
      lastName: optionalStringField(CARD, row, "last_name"),
      phone: optionalStringField(CARD, row, "phone"),
      city: optionalStringField(CARD, row, "city"),
      groomName: optionalStringField(CARD, row, "groom_name"),
      weddingDate: optionalDateField(CARD, row, "wedding_date"),
      weddingDateSource: enumField(CARD, row, "wedding_date_source", CALENDAR_SYSTEMS),
      referralSource: optionalStringField(CARD, row, "referral_source"),
      status: enumField(CARD, row, "status", BRIDE_STATUSES),
      portalExpiresAt: optionalStringField(CARD, row, "portal_expires_at"),
      currency,
      courses: courses
        .map(({ row: c, sessions, payments }): CardCourse => {
          const price = optionalDecimalField(CARD, c, "agreed_price");
          return {
            id: uuidField(CARD, c, "id"),
            status: enumField(CARD, c, "status", COURSE_STATUSES),
            startDate: optionalDateField(CARD, c, "start_date"),
            targetEndDate: optionalDateField(CARD, c, "target_end_date"),
            bufferDays: intField(CARD, c, "buffer_days"),
            agreedPrice: price === null ? null : { amount: price, currency },
            curriculumSnapshot: c.curriculum_snapshot,
            sessions: sessions
              .map((s): CardSession => {
                const sid = uuidField(CARD, s, "id");
                return {
                  id: sid,
                  orderIndex: intField(CARD, s, "order_index"),
                  scheduledAt: optionalStringField(CARD, s, "scheduled_at"),
                  durationMinutes: intField(CARD, s, "duration_minutes"),
                  location: optionalStringField(CARD, s, "location"),
                  status: enumField(CARD, s, "status", SESSION_STATUSES),
                  isPinned: boolField(CARD, s, "is_pinned"),
                  rescheduledFromSessionId: optionalUuidField(
                    CARD,
                    s,
                    "rescheduled_from_session_id",
                  ),
                  record: records.get(sid) ?? null,
                };
              })
              .sort((a, b) => a.orderIndex - b.orderIndex || compareNullable(a.scheduledAt, b.scheduledAt)),
            payments: payments
              .map((p): CardPayment => {
                const paidAt = optionalDateField(CARD, p, "paid_at");
                const amount = optionalDecimalField(CARD, p, "amount");
                if (paidAt === null || amount === null) fail(CARD, { code: "shape" });
                return {
                  id: uuidField(CARD, p, "id"),
                  amount: { amount, currency: currencyField(CARD, p, "currency") },
                  method: enumField(CARD, p, "method", PAYMENT_METHODS),
                  payer: enumField(CARD, p, "payer", PAYERS),
                  paidAt,
                  receiptNumber: optionalStringField(CARD, p, "receipt_number"),
                };
              })
              .sort((a, b) => (a.paidAt < b.paidAt ? -1 : a.paidAt > b.paidAt ? 1 : 0)),
          };
        })
        .sort((a, b) => compareNullable(a.targetEndDate, b.targetEndDate)),
    };

    ctx.subject(card.id);
    return card;
  },
);

function compareNullable(a: string | null, b: string | null): number {
  if (a === b) return 0;
  if (a === null) return 1;
  if (b === null) return -1;
  return a < b ? -1 : 1;
}

/* ── createBride ─────────────────────────────────────────────────────────── */

/**
 * Deliberately has no `id`: ids are generated by the database
 * (`gen_random_uuid()`), never taken from input. An insert carrying another
 * tenant's existing id fails with `23505`, which would confirm that id exists
 * (security review of #55). `brides.test.ts` asserts the insert payload.
 */
export type NewBride = {
  readonly firstName: string;
  readonly lastName?: string | null;
  readonly phone?: string | null;
  readonly city?: string | null;
  readonly groomName?: string | null;
  readonly weddingDate?: CalendarDate | null;
  readonly weddingDateSource?: (typeof CALENDAR_SYSTEMS)[number];
  readonly referralSource?: string | null;
  readonly status?: BrideStatus;
  readonly id?: never;
  readonly tenantId?: never;
};

export type NewBrideField = "firstName" | "phone" | "weddingDate" | "status";

const CREATE = "bride.insert";
const MAX_TEXT = 200;

function optText(v: string | null | undefined): string | null {
  if (v === null || v === undefined) return null;
  const t = String(v).trim();
  return t === "" ? null : t.slice(0, MAX_TEXT);
}

/** Creates a bride for the signed-in instructor. Phone is stored as E.164. */
export const createBride = defineMutation(
  { resource: "bride", action: "create", subjects: "per-bride" },
  async (ctx, input: NewBride): Promise<FormResult<{ id: Uuid }, NewBrideField>> => {
    const invalid: NewBrideField[] = [];
    const firstName = optText(input.firstName);
    if (!firstName) invalid.push("firstName");

    let phone: string | null = null;
    if (optText(input.phone)) {
      phone = normalisePhoneE164(String(input.phone));
      if (!phone) invalid.push("phone");
    }
    const weddingDate =
      input.weddingDate == null ? null : tryParseCalendarDate(String(input.weddingDate));
    if (input.weddingDate != null && weddingDate === null) invalid.push("weddingDate");
    const status = input.status ?? "lead";
    if (!(BRIDE_STATUSES as readonly string[]).includes(status)) invalid.push("status");
    const source = input.weddingDateSource ?? "gregorian";
    if (invalid.length > 0) return { ok: false, invalid };

    // Built field by field: nothing from `input` is spread, so no `id` (or any
    // other column) can ride along.
    const { data, error } = await ctx.db
      .from("bride")
      .insert({
        tenant_id: ctx.tenantId,
        first_name: firstName,
        last_name: optText(input.lastName),
        phone,
        city: optText(input.city),
        groom_name: optText(input.groomName),
        wedding_date: weddingDate,
        wedding_date_source: (CALENDAR_SYSTEMS as readonly string[]).includes(source)
          ? source
          : "gregorian",
        referral_source: optText(input.referralSource),
        status,
      })
      .select("id")
      .single();
    if (error) fail(CREATE, error);
    const id = uuidField(CREATE, asRow(CREATE, data), "id");
    ctx.subject(id);
    return ok({ id });
  },
);
