import { beforeEach, describe, expect, it, vi } from "vitest";

import { readSessionRecords, upsertSessionRecord } from "./records";
import { FakeClient, TENANT, UUID_RE, hasOp } from "./testing/fake-client";

const state = vi.hoisted(() => ({ client: undefined as unknown }));
vi.mock("@/lib/supabase/user", () => ({ createUserClient: async () => state.client }));

const BRIDE = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const COURSE = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const S1 = "dddddddd-dddd-4ddd-8ddd-ddddddddddd1";
const S2 = "dddddddd-dddd-4ddd-8ddd-ddddddddddd2";
const TOPIC = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const NOTE = "She is anxious about the mikveh; her mother is ill.";

let fake: FakeClient;
beforeEach(() => {
  fake = new FakeClient();
  state.client = fake;
});

describe("readSessionRecords", () => {
  it("reads only through the audited reader and writes no access_log row of its own", async () => {
    fake.respondRpc("read_session_records", {
      data: [
        { session_id: S1, course_id: COURSE, bride_id: BRIDE, order_index: 1,
          covered_topic_ids: [TOPIC], private_note: NOTE, needs_review_note: null,
          updated_at: "2026-10-01T10:00:00Z" },
      ],
    });
    const records = await readSessionRecords([S1, S1, "junk", S2]);
    expect(records).toEqual([
      { sessionId: S1, courseId: COURSE, brideId: BRIDE, orderIndex: 1, coveredTopicIds: [TOPIC],
        privateNote: NOTE, needsReviewNote: null, updatedAt: "2026-10-01T10:00:00Z" },
    ]);
    expect(fake.queries).toHaveLength(0); // no .from("session_record"), no access_log insert
    expect(fake.rpcs).toEqual([
      { name: "read_session_records",
        args: { p_session_ids: [S1, S2], p_request_id: expect.stringMatching(UUID_RE) } },
    ]);
  });

  it("makes no call for no valid ids", async () => {
    await expect(readSessionRecords(["nope"])).resolves.toEqual([]);
    expect(fake.rpcs).toHaveLength(0);
  });
});

describe("upsertSessionRecord", () => {
  const input = { sessionId: S1, coveredTopicIds: [TOPIC], privateNote: NOTE, needsReviewNote: "review" };

  it("writes through upsert_session_record, never .upsert(), and logs ids only", async () => {
    fake.respond("session", { data: { id: S1, course: { bride_id: BRIDE } } });
    fake.respondRpc("upsert_session_record", {
      data: [{ session_id: S1, created_at: "x", updated_at: "2026-10-05T10:00:00Z" }],
    });
    await expect(upsertSessionRecord(input)).resolves.toEqual({
      ok: true,
      value: { sessionId: S1, updatedAt: "2026-10-05T10:00:00Z" },
    });

    const lookup = fake.dataQueries[0]!;
    expect(lookup.table).toBe("session");
    expect(hasOp(lookup, "eq", "tenant_id", TENANT)).toBe(true);
    expect(fake.queries.some((q) => q.table === "session_record")).toBe(false);
    expect(fake.rpcs[0]).toEqual({
      name: "upsert_session_record",
      args: { p_session_id: S1, p_covered_topic_ids: [TOPIC], p_private_note: NOTE, p_needs_review_note: "review" },
    });

    expect(fake.accessLogRows).toEqual([
      expect.objectContaining({ bride_id: BRIDE, action: "update", resource: "session_record" }),
    ]);
    // the note never reaches the log
    expect(JSON.stringify(fake.accessLogRows)).not.toContain("mikveh");
    expect(JSON.stringify(fake.accessLogRows)).not.toContain("review");
  });

  it("is a bare { ok: false } for a session that is not hers, writing nothing", async () => {
    fake.respond("session", { data: null });
    await expect(upsertSessionRecord(input)).resolves.toStrictEqual({ ok: false });
    expect(fake.rpcs).toHaveLength(0);
    expect(fake.accessLogRows).toHaveLength(0);
  });

  it("maps the RPC's P0002 to { ok: false }", async () => {
    fake.respond("session", { data: { id: S1, course: { bride_id: BRIDE } } });
    fake.respondRpc("upsert_session_record", { error: { code: "P0002" } });
    await expect(upsertSessionRecord(input)).resolves.toStrictEqual({ ok: false });
    expect(fake.accessLogRows).toHaveLength(0);
  });

  it("rejects non-uuid topic ids before touching the database", async () => {
    await expect(upsertSessionRecord({ ...input, coveredTopicIds: ["topic one"] })).resolves.toStrictEqual({ ok: false });
    expect(fake.queries).toHaveLength(0);
  });
});
