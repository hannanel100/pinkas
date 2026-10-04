import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";

import { beforeAll, describe, expect, it, vi } from "vitest";

import { postgrestClient } from "@/lib/supabase/testing/postgrest-client";

import { createBride, getBrideCard, listBrides } from "./brides";
import { confirmSchedule, createCourse, recomputeSchedule } from "./courses";
import { bootstrapInstructor } from "./instructor";
import { readSessionRecords, upsertSessionRecord } from "./records";
import { cancel, markDone, reschedule } from "./sessions";
import { getTodayScreen } from "./today";

/**
 * `lib/data/` against real Postgres + PostgREST, built from
 * `supabase/migrations/` — real RLS, real grants, real RPCs. Opt-in: set
 *
 *   PINKAS_IT_POSTGREST_URL   e.g. http://127.0.0.1:3000
 *   PINKAS_IT_JWT_SECRET      PostgREST's jwt-secret
 *   PINKAS_IT_DATABASE_URL    superuser URL of the same database, for assertions
 *
 * Skipped otherwise; wiring it into CI is `qa`'s (ci.yml).
 *
 * The superuser connection only READS, to assert what the data layer wrote —
 * above all the access log. Every fixture is created through `lib/data/`.
 */

const URL_ = process.env.PINKAS_IT_POSTGREST_URL;
const SECRET = process.env.PINKAS_IT_JWT_SECRET;
const DB = process.env.PINKAS_IT_DATABASE_URL;

const state = vi.hoisted(() => ({ claims: {} as Record<string, unknown> }));
vi.mock("@/lib/supabase/user", () => ({
  createUserClient: async () => postgrestClient(URL_!, SECRET!, state.claims),
}));

function as(tenant: string) {
  state.claims = { sub: tenant, role: "authenticated" };
}

function sql(query: string): string {
  return execFileSync("psql", [DB!, "-Atq", "-v", "ON_ERROR_STOP=1", "-c", query], {
    encoding: "utf8",
  }).trim();
}

const A = randomUUID();
const B = randomUUID();
const NOTE = `secret note ${randomUUID()}`;
const templates = [{ name: "reminder", body: "שלום {{bride_name}}, נתראה ב-{{date}}" }];
const curriculum = {
  name: "מסלול",
  defaultSessionCount: 3,
  topics: [{ title: "א" }, { title: "ב" }, { title: "ג" }],
};

let brideA: string;
let courseA: string;
let sessions: { id: string; order_index: number }[];

describe.skipIf(!URL_ || !SECRET || !DB)("lib/data against Postgres + PostgREST", () => {
  beforeAll(async () => {
    for (const [tenant, phone] of [[A, "050-111-1111"], [B, "050-222-2222"]] as const) {
      as(tenant);
      const r = await bootstrapInstructor({ fullName: "מדריכה", phone, templates, curriculum });
      expect(r).toEqual({ ok: true, value: { instructorId: tenant, wasCreated: true } });
    }
  });

  it("bootstrap is idempotent and seeded the templates", async () => {
    as(A);
    await expect(bootstrapInstructor({ fullName: "מדריכה", phone: "0501111111", templates, curriculum })).resolves.toEqual({
      ok: true,
      value: { instructorId: A, wasCreated: false },
    });
    expect(sql(`select count(*) from message_template where tenant_id = '${A}' and is_system`)).toBe("1");
    expect(sql(`select phone from instructor where id = '${A}'`)).toBe("+972501111111");
  });

  it("creates a bride, a course with a snapshot, and confirms a proposed schedule", async () => {
    as(A);
    const bride = await createBride({ firstName: "נועה", phone: "054-765-4321", weddingDate: "2026-12-20" as never });
    expect(bride.ok).toBe(true);
    brideA = (bride as { value: { id: string } }).value.id;
    expect(sql(`select phone from bride where id = '${brideA}'`)).toBe("+972547654321");

    const curId = sql(`select id from curriculum where tenant_id = '${A}'`);
    const course = await createCourse({ brideId: brideA, curriculumId: curId, agreedPrice: "2400.50" });
    expect(course.ok).toBe(true);
    courseA = (course as { value: { id: string } }).value.id;
    expect(sql(`select target_end_date || ' ' || agreed_price || ' ' || status || ' ' || jsonb_array_length(curriculum_snapshot->'topics') from course where id = '${courseA}'`))
      .toBe("2026-12-06 2400.50 draft 3");

    const proposal = await recomputeSchedule(courseA, { cadence: { kind: "perWeek", n: 1 } });
    expect(proposal.ok).toBe(true);
    if (!proposal.ok) return;
    expect(sql(`select count(*) from session where course_id = '${courseA}'`)).toBe("0"); // proposes, never writes

    const slots = proposal.value.proposal.slots.map((s) => ({ orderIndex: s.orderIndex, date: s.date }));
    const confirmed = await confirmSchedule({ courseId: courseA, slots, time: "18:00", location: "בית" });
    expect(confirmed.ok).toBe(true);
    expect(sql(`select status from course where id = '${courseA}'`)).toBe("active");
    expect(
      sql(`select string_agg(distinct to_char(scheduled_at at time zone 'Asia/Jerusalem', 'HH24:MI'), ',') from session where course_id = '${courseA}'`),
    ).toBe("18:00");
    sessions = JSON.parse(
      sql(`select json_agg(json_build_object('id', id, 'order_index', order_index) order by order_index) from session where course_id = '${courseA}'`),
    );
    expect(sessions).toHaveLength(3);

    // a retry converges instead of duplicating
    await confirmSchedule({ courseId: courseA, slots, time: "18:00" });
    expect(sql(`select count(*) from session where course_id = '${courseA}'`)).toBe("3");
  });

  it("marks done, writes a private record, and reads the card through the audited reader", async () => {
    as(A);
    await expect(markDone(sessions[0]!.id)).resolves.toEqual({ ok: true, value: { sessionId: sessions[0]!.id } });
    const up = await upsertSessionRecord({
      sessionId: sessions[0]!.id,
      coveredTopicIds: [],
      privateNote: NOTE,
      needsReviewNote: "carry forward",
    });
    expect(up.ok).toBe(true);

    const card = await getBrideCard(brideA);
    expect(card?.courses[0]?.sessions[0]?.record?.privateNote).toBe(NOTE);
    expect(card?.courses[0]?.agreedPrice).toEqual({ amount: "2400.50", currency: "ILS" });

    // two resources, one request id — what was disclosed, not which function ran
    const rows = sql(
      `select resource || ':' || actor_kind from access_log where tenant_id = '${A}' and request_id = (
         select request_id from access_log where tenant_id = '${A}' and resource = 'bride_card' order by id desc limit 1)
       order by resource`,
    );
    expect(rows.split("\n")).toEqual(["bride_card:instructor", "session_record:instructor"]);
  });

  it("reschedules a cancelled session into a linked replacement", async () => {
    as(A);
    const s = sessions[1]!.id;
    await expect(cancel(s)).resolves.toMatchObject({ ok: true });
    const r = await reschedule(s, { date: "2026-11-30" as never, time: "10:15" });
    expect(r.ok).toBe(true);
    expect(sql(`select status from session where id = '${s}'`)).toBe("cancelled");
    expect(
      sql(`select to_char(scheduled_at at time zone 'Asia/Jerusalem', 'YYYY-MM-DD HH24:MI') || ' ' || is_pinned from session where rescheduled_from_session_id = '${s}'`),
    ).toBe("2026-11-30 10:15 true");
  });

  it("Today is one RPC whose log rows are written in-database", async () => {
    as(A);
    const before = Number(sql(`select count(*) from access_log where tenant_id = '${A}' and resource = 'today_screen'`));
    const screen = await getTodayScreen();
    expect(screen.payments.outstanding.currency).toBe("ILS");
    expect(screen.risk.length + screen.onTrackCount).toBe(1);
    const after = Number(sql(`select count(*) from access_log where tenant_id = '${A}' and resource = 'today_screen'`));
    expect(after - before).toBe(1); // one bride in the document
  });

  it("another tenant sees and changes nothing — refused in the query AND by RLS", async () => {
    as(B);
    await expect(listBrides()).resolves.toEqual([]);
    await expect(getBrideCard(brideA)).resolves.toBeNull();
    await expect(readSessionRecords(sessions.map((s) => s.id))).resolves.toEqual([]);
    await expect(markDone(sessions[2]!.id)).resolves.toStrictEqual({ ok: false });
    await expect(cancel(sessions[2]!.id)).resolves.toStrictEqual({ ok: false });
    await expect(reschedule(sessions[2]!.id, null)).resolves.toStrictEqual({ ok: false });
    await expect(
      upsertSessionRecord({ sessionId: sessions[2]!.id, coveredTopicIds: [], privateNote: "x", needsReviewNote: null }),
    ).resolves.toStrictEqual({ ok: false });
    await expect(
      confirmSchedule({ courseId: courseA, slots: [{ orderIndex: 3, date: "2026-11-01" as never }], time: "09:00" }),
    ).resolves.toStrictEqual({ ok: false });
    const curB = sql(`select id from curriculum where tenant_id = '${B}'`);
    await expect(createCourse({ brideId: brideA, curriculumId: curB })).resolves.toEqual({ ok: false, invalid: ["brideId"] });
    await expect(getTodayScreen()).resolves.toMatchObject({ risk: [], onTrackCount: 0, sessionsToday: [] });

    expect(sql(`select status || ' ' || coalesce(to_char(scheduled_at, 'YYYY'), '-') from session where id = '${sessions[2]!.id}'`)).toMatch(/^planned 20\d\d$/);
    expect(sql(`select count(*) from session_record where tenant_id = '${B}'`)).toBe("0");
    expect(sql(`select count(*) from access_log where tenant_id = '${B}'`)).toBe("0");
  });

  it("the access log holds identifiers only, attributed to the tenant", async () => {
    expect(sql(`select count(*) from access_log a where a::text like '%secret note%'`)).toBe("0");
    expect(sql(`select count(*) from access_log where tenant_id = '${A}' and (actor_kind <> 'instructor' or actor_id <> tenant_id)`)).toBe("0");
    expect(
      sql(`select count(*) from access_log where tenant_id = '${A}' and request_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'`),
    ).toBe("0");
    expect(sql(`select string_agg(distinct resource, ',' order by resource) from access_log where tenant_id = '${A}'`)).toBe(
      "bride,bride_card,course,schedule,session,session_record,today_screen",
    );
  });
});
