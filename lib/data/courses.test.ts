import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { confirmSchedule, createCourse, recomputeSchedule, type NewCourse } from "./courses";
import { FakeClient, TENANT, UUID_RE, hasOp, opsOf } from "./testing/fake-client";

const state = vi.hoisted(() => ({ client: undefined as unknown }));
vi.mock("@/lib/supabase/user", () => ({ createUserClient: async () => state.client }));

const BRIDE = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const CUR = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const COURSE = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const T1 = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1";
const T2 = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2";
const S1 = "dddddddd-dddd-4ddd-8ddd-ddddddddddd1";
const S2 = "dddddddd-dddd-4ddd-8ddd-ddddddddddd2";
const OTHER = "ffffffff-ffff-4fff-8fff-ffffffffffff";

let fake: FakeClient;
beforeEach(() => {
  fake = new FakeClient();
  state.client = fake;
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-10-04T09:00:00Z"));
});
afterEach(() => vi.useRealTimers());

const curriculumRow = {
  id: CUR, name: "מסלול בסיסי", description: null, default_session_count: 4, default_price: "2400.00",
  curriculum_topic: [
    { id: T2, order_index: 2, title: "ב", description: null, estimated_minutes: 60, deleted_at: null },
    { id: T1, order_index: 1, title: "א", description: null, estimated_minutes: null, deleted_at: null },
    { id: OTHER, order_index: 3, title: "deleted", description: null, estimated_minutes: null, deleted_at: "2026-01-01" },
  ],
};

const snapshot = {
  curriculum: { id: CUR, name: "מסלול בסיסי", description: null, defaultSessionCount: 4 },
  topics: [
    { id: T1, orderIndex: 1, title: "א", description: null, estimatedMinutes: null },
    { id: T2, orderIndex: 2, title: "ב", description: null, estimatedMinutes: 60 },
  ],
};

describe("createCourse", () => {
  it("freezes the curriculum into a snapshot, derives the deadline, and logs the bride", async () => {
    fake.respond("curriculum", { data: curriculumRow });
    fake.respond("bride", {
      data: { id: BRIDE, wedding_date: "2027-03-01", instructor: { default_buffer_days: 14, default_price: null } },
    });
    fake.respond("course", { data: { id: COURSE } });

    await expect(createCourse({ brideId: BRIDE, curriculumId: CUR })).resolves.toEqual({
      ok: true,
      value: { id: COURSE },
    });
    const [cur, bride, ins] = fake.dataQueries;
    expect(hasOp(cur!, "eq", "tenant_id", TENANT)).toBe(true);
    expect(hasOp(bride!, "eq", "tenant_id", TENANT)).toBe(true);
    const row = opsOf(ins!, "insert")[0]![0] as Record<string, unknown>;
    expect(row).not.toHaveProperty("id");
    expect(row).toMatchObject({
      tenant_id: TENANT, bride_id: BRIDE, curriculum_id: CUR, snapshot_version: 1,
      target_end_date: "2027-02-15", buffer_days: 14, agreed_price: "2400.00", status: "draft",
    });
    expect(row.curriculum_snapshot).toEqual(snapshot);
    expect(fake.accessLogRows).toEqual([expect.objectContaining({ bride_id: BRIDE, resource: "course", action: "create" })]);
  });

  it("never forwards a client-supplied id", async () => {
    // @ts-expect-error — NewCourse has no id.
    const typed: NewCourse = { brideId: BRIDE, curriculumId: CUR, id: OTHER };
    void typed;
    fake.respond("curriculum", { data: curriculumRow });
    fake.respond("bride", { data: { id: BRIDE, wedding_date: null, instructor: { default_buffer_days: 14, default_price: null } } });
    fake.respond("course", { data: { id: COURSE } });
    await createCourse({ brideId: BRIDE, curriculumId: CUR, id: OTHER } as unknown as NewCourse);
    const row = opsOf(fake.dataQueries[2]!, "insert")[0]![0] as Record<string, unknown>;
    expect(row).not.toHaveProperty("id");
    expect(row.target_end_date).toBeNull();
  });

  it("refuses a float price and another tenant's curriculum", async () => {
    await expect(createCourse({ brideId: BRIDE, curriculumId: CUR, agreedPrice: "24.999" })).resolves.toEqual({
      ok: false,
      invalid: ["agreedPrice"],
    });
    fake.respond("curriculum", { data: null });
    fake.respond("bride", { data: null });
    await expect(createCourse({ brideId: BRIDE, curriculumId: OTHER })).resolves.toEqual({
      ok: false,
      invalid: ["curriculumId"],
    });
    expect(fake.accessLogRows).toHaveLength(0);
  });
});

const courseRow = (sessions: unknown[], status = "active") => ({
  id: COURSE, status, start_date: null, buffer_days: 14, snapshot_version: 1, curriculum_snapshot: snapshot,
  bride: { id: BRIDE, wedding_date: "2027-03-01", deleted_at: null },
  session: sessions,
});

const sess = (over: Record<string, unknown>) => ({
  id: S1, order_index: 1, scheduled_at: null, status: "planned", is_pinned: false, location: null,
  duration_minutes: 60, deleted_at: null, ...over,
});

describe("recomputeSchedule", () => {
  it("returns a proposal and writes nothing (§7.5)", async () => {
    fake.respond("course", {
      data: courseRow([sess({ id: S1, order_index: 1, status: "done", scheduled_at: "2026-09-20T15:00:00Z" })]),
    });
    fake.respond("blackout_date", { data: [] });
    const result = await recomputeSchedule(COURSE, { cadence: { kind: "perWeek", n: 1 } });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const slots = result.value.proposal.slots;
    expect(slots).toHaveLength(4);
    expect(slots.find((s) => s.orderIndex === 1)).toMatchObject({ source: "completed", date: "2026-09-20" });
    for (const q of fake.dataQueries) {
      for (const m of ["insert", "update", "upsert", "delete"]) expect(opsOf(q, m)).toHaveLength(0);
    }
    expect(fake.accessLogRows).toEqual([expect.objectContaining({ bride_id: BRIDE, resource: "schedule", action: "read" })]);
  });

  it("refuses a bad cadence and a course that is not hers", async () => {
    await expect(recomputeSchedule(COURSE, { cadence: { kind: "perWeek", n: 0 } })).resolves.toStrictEqual({ ok: false });
    fake.respond("course", { data: null });
    await expect(recomputeSchedule(COURSE, { cadence: { kind: "perWeek", n: 1 } })).resolves.toStrictEqual({ ok: false });
    expect(fake.accessLogRows).toHaveLength(0);
  });
});

describe("confirmSchedule", () => {
  it("moves unpinned planned sessions, creates the rest with server ids, never touches done/pinned", async () => {
    fake.respond("course", {
      data: courseRow(
        [
          sess({ id: S1, order_index: 1, status: "done", scheduled_at: "2026-09-20T15:00:00Z" }),
          sess({ id: S2, order_index: 2, status: "planned", location: "בית" }),
          sess({ id: OTHER, order_index: 3, status: "planned", is_pinned: true, scheduled_at: "2026-11-01T15:00:00Z" }),
        ],
        "draft",
      ),
    });
    const result = await confirmSchedule({
      courseId: COURSE,
      time: "18:00",
      slots: [
        { orderIndex: 1, date: "2026-10-10" as never },
        { orderIndex: 2, date: "2026-10-17" as never },
        { orderIndex: 3, date: "2026-10-24" as never },
        { orderIndex: 4, date: "2026-10-31" as never },
      ],
    });
    expect(result.ok).toBe(true);

    const upsert = fake.dataQueries.find((q) => q.table === "session" && opsOf(q, "upsert").length > 0)!;
    const [rows, opts] = opsOf(upsert, "upsert")[0]! as [Record<string, unknown>[], unknown];
    expect(opts).toEqual({ onConflict: "id" });
    expect(rows.map((r) => r.order_index)).toEqual([2, 4]);
    expect(rows[0]).toMatchObject({ id: S2, location: "בית", scheduled_at: "2026-10-17 18:00:00 Asia/Jerusalem" });
    expect(rows[1]!.id).toMatch(UUID_RE);
    expect([S1, S2, OTHER]).not.toContain(rows[1]!.id);
    for (const r of rows) expect(r.tenant_id).toBe(TENANT);

    const activate = fake.dataQueries.find((q) => q.table === "course" && opsOf(q, "update").length > 0)!;
    expect(opsOf(activate, "update")[0]).toEqual([{ status: "active" }]);
    expect(fake.accessLogRows).toEqual([expect.objectContaining({ bride_id: BRIDE, resource: "schedule", action: "update" })]);
  });

  it("rejects duplicate indices, bad times and completed courses", async () => {
    await expect(
      confirmSchedule({ courseId: COURSE, time: "18:00", slots: [
        { orderIndex: 1, date: "2026-10-10" as never }, { orderIndex: 1, date: "2026-10-11" as never }] }),
    ).resolves.toStrictEqual({ ok: false });
    await expect(confirmSchedule({ courseId: COURSE, time: "6pm", slots: [] })).resolves.toStrictEqual({ ok: false });
    fake.respond("course", { data: courseRow([], "completed") });
    await expect(confirmSchedule({ courseId: COURSE, time: "18:00", slots: [] })).resolves.toStrictEqual({ ok: false });
    expect(fake.accessLogRows).toHaveLength(0);
  });
});
