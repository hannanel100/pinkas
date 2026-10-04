import { beforeEach, describe, expect, it, vi } from "vitest";

import { cancel, markDone, reschedule } from "./sessions";
import { FakeClient, TENANT, hasOp, opsOf } from "./testing/fake-client";

const state = vi.hoisted(() => ({ client: undefined as unknown }));
vi.mock("@/lib/supabase/user", () => ({ createUserClient: async () => state.client }));

const BRIDE = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const COURSE = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const S1 = "dddddddd-dddd-4ddd-8ddd-ddddddddddd1";
const NEW = "dddddddd-dddd-4ddd-8ddd-ddddddddddd9";

let fake: FakeClient;
beforeEach(() => {
  fake = new FakeClient();
  state.client = fake;
});

describe("markDone / cancel", () => {
  it("markDone moves planned+scheduled → done, tenant-scoped, and logs the bride", async () => {
    fake.respond("session", { data: [{ id: S1, course: { bride_id: BRIDE } }] });
    await expect(markDone(S1)).resolves.toEqual({ ok: true, value: { sessionId: S1 } });
    const q = fake.dataQueries[0]!;
    expect(opsOf(q, "update")[0]).toEqual([{ status: "done" }]);
    expect(hasOp(q, "eq", "tenant_id", TENANT)).toBe(true);
    expect(hasOp(q, "eq", "status", "planned")).toBe(true);
    expect(hasOp(q, "not", "scheduled_at", "is", null)).toBe(true);
    expect(fake.accessLogRows).toEqual([
      expect.objectContaining({ bride_id: BRIDE, action: "update", resource: "session" }),
    ]);
  });

  it("cancel keeps the row (never deletes) and does not require a date", async () => {
    fake.respond("session", { data: [{ id: S1, course: { bride_id: BRIDE } }] });
    await cancel(S1);
    const q = fake.dataQueries[0]!;
    expect(opsOf(q, "update")[0]).toEqual([{ status: "cancelled" }]);
    expect(opsOf(q, "delete")).toHaveLength(0);
    expect(hasOp(q, "not", "scheduled_at", "is", null)).toBe(false);
  });

  it("is a bare { ok: false } when nothing matched, with no log row", async () => {
    fake.respond("session", { data: [] });
    await expect(markDone(S1)).resolves.toStrictEqual({ ok: false });
    await expect(cancel("not-an-id")).resolves.toStrictEqual({ ok: false });
    expect(fake.accessLogRows).toHaveLength(0);
  });
});

describe("reschedule", () => {
  const original = (status: string) => ({
    id: S1, course_id: COURSE, order_index: 3, status, location: "בית", duration_minutes: 60,
    course: { bride_id: BRIDE, status: "active" },
  });

  it("rebooks a planned session: replacement linked and pinned, original retired, ids from the database", async () => {
    fake.respond("session", { data: original("planned") });
    fake.respond("session", { data: [] }); // no prior replacement
    fake.respond("session", { data: { id: NEW } }); // insert
    fake.respond("session", { data: null }); // retire
    await expect(reschedule(S1, { date: "2026-10-20" as never, time: "18:30" })).resolves.toEqual({
      ok: true,
      value: { sessionId: NEW },
    });

    const [, , ins, retire] = fake.dataQueries;
    const row = opsOf(ins!, "insert")[0]![0] as Record<string, unknown>;
    expect(row).not.toHaveProperty("id");
    expect(row).toMatchObject({
      tenant_id: TENANT, course_id: COURSE, order_index: 3, status: "planned", is_pinned: true,
      rescheduled_from_session_id: S1, scheduled_at: "2026-10-20 18:30:00 Asia/Jerusalem",
    });
    expect(opsOf(retire!, "update")[0]).toEqual([{ status: "rescheduled" }]);
    expect(fake.accessLogRows).toEqual([expect.objectContaining({ bride_id: BRIDE, resource: "session" })]);
  });

  it("rebooks a cancelled session without touching it, and unpinned when undated", async () => {
    fake.respond("session", { data: original("cancelled") });
    fake.respond("session", { data: [] });
    fake.respond("session", { data: { id: NEW } });
    await reschedule(S1, null);
    expect(fake.dataQueries).toHaveLength(3);
    const row = opsOf(fake.dataQueries[2]!, "insert")[0]![0] as Record<string, unknown>;
    expect(row).toMatchObject({ scheduled_at: null, is_pinned: false });
  });

  it("is idempotent: an existing replacement is moved, not duplicated", async () => {
    fake.respond("session", { data: original("cancelled") });
    fake.respond("session", { data: [{ id: NEW }] });
    fake.respond("session", { data: null });
    await expect(reschedule(S1, { date: "2026-10-20" as never, time: "09:00" })).resolves.toEqual({
      ok: true,
      value: { sessionId: NEW },
    });
    expect(fake.dataQueries.flatMap((q) => opsOf(q, "insert"))).toHaveLength(0);
  });

  it("refuses done sessions, bad times, and foreign ids", async () => {
    fake.respond("session", { data: original("done") });
    await expect(reschedule(S1, null)).resolves.toStrictEqual({ ok: false });
    await expect(reschedule(S1, { date: "2026-10-20" as never, time: "25:00" })).resolves.toStrictEqual({ ok: false });
    fake.respond("session", { data: null });
    await expect(reschedule(S1, null)).resolves.toStrictEqual({ ok: false });
    expect(fake.accessLogRows).toHaveLength(0);
  });
});
