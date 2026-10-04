import { beforeEach, describe, expect, it, vi } from "vitest";

import { createBride, getBrideCard, listBrides, type NewBride } from "./brides";
import { FakeClient, TENANT, hasOp, opsOf } from "./testing/fake-client";

const state = vi.hoisted(() => ({ client: undefined as unknown }));
vi.mock("@/lib/supabase/user", () => ({ createUserClient: async () => state.client }));

const B1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1";
const B2 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2";
const OTHER = "ffffffff-ffff-4fff-8fff-ffffffffffff";
const C1 = "cccccccc-cccc-4ccc-8ccc-ccccccccccc1";
const S1 = "dddddddd-dddd-4ddd-8ddd-ddddddddddd1";
const S2 = "dddddddd-dddd-4ddd-8ddd-ddddddddddd2";
const P1 = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1";

let fake: FakeClient;
beforeEach(() => {
  fake = new FakeClient();
  state.client = fake;
});

describe("listBrides", () => {
  it("is tenant-scoped in the query, never selects the portal hash, and logs one row per bride", async () => {
    fake.respond("bride", {
      data: [
        { id: B1, first_name: "נועה", last_name: null, phone: "+972501234567", wedding_date: "2027-01-01", status: "active" },
        { id: B2, first_name: "רחל", last_name: "לוי", phone: null, wedding_date: null, status: "lead" },
      ],
    });
    const brides = await listBrides();
    expect(brides.map((b) => b.id)).toEqual([B1, B2]);

    const q = fake.dataQueries[0]!;
    expect(hasOp(q, "eq", "tenant_id", TENANT)).toBe(true);
    expect(hasOp(q, "is", "deleted_at", null)).toBe(true);
    expect(JSON.stringify(opsOf(q, "select"))).not.toContain("portal_token_hash");

    expect(fake.accessLogRows.map((r) => [r.bride_id, r.action, r.resource])).toEqual([
      [B1, "read", "bride"],
      [B2, "read", "bride"],
    ]);
  });

  it("writes no log row for an empty list", async () => {
    await expect(listBrides()).resolves.toEqual([]);
    expect(fake.accessLogRows).toHaveLength(0);
  });
});

describe("getBrideCard", () => {
  const cardRow = {
    id: B1, first_name: "נועה", last_name: "כהן", phone: "+972501234567", city: null, groom_name: null,
    wedding_date: "2027-01-01", wedding_date_source: "hebrew", referral_source: null, status: "active",
    portal_expires_at: null,
    instructor: { currency: "ILS" },
    course: [
      {
        id: C1, status: "active", start_date: null, target_end_date: "2026-12-18", buffer_days: 14,
        agreed_price: "2400.00", curriculum_snapshot: {}, deleted_at: null,
        session: [
          { id: S2, order_index: 2, scheduled_at: null, duration_minutes: 60, location: null,
            status: "planned", is_pinned: false, rescheduled_from_session_id: null, deleted_at: null },
          { id: S1, order_index: 1, scheduled_at: "2026-10-01T15:00:00+00:00", duration_minutes: 60,
            location: "בית", status: "done", is_pinned: false, rescheduled_from_session_id: null, deleted_at: null },
          { id: OTHER, order_index: 3, scheduled_at: null, duration_minutes: 60, location: null,
            status: "planned", is_pinned: false, rescheduled_from_session_id: null, deleted_at: "2026-01-01" },
        ],
        payment: [
          { id: P1, amount: "800.00", currency: "ILS", method: "bit", payer: "bride", paid_at: "2026-09-01",
            receipt_number: null, deleted_at: null },
        ],
      },
    ],
  };

  it("returns the card with records, and the two log sources share one request id", async () => {
    fake.respond("bride", { data: cardRow });
    fake.respondRpc("read_session_records", {
      data: [{ session_id: S1, course_id: C1, bride_id: B1, order_index: 1, covered_topic_ids: [],
        private_note: "note", needs_review_note: "carry forward", updated_at: "2026-10-01T16:00:00Z" }],
    });
    const card = await getBrideCard(B1);
    expect(card).not.toBeNull();
    const course = card!.courses[0]!;
    expect(course.sessions.map((s) => s.id)).toEqual([S1, S2]); // ordered, soft-deleted dropped
    expect(course.sessions[0]!.record?.needsReviewNote).toBe("carry forward");
    expect(course.agreedPrice).toEqual({ amount: "2400.00", currency: "ILS" });
    expect(course.payments[0]!.amount).toEqual({ amount: "800.00", currency: "ILS" });

    const q = fake.dataQueries[0]!;
    expect(hasOp(q, "eq", "id", B1)).toBe(true);
    expect(hasOp(q, "eq", "tenant_id", TENANT)).toBe(true);
    const select = JSON.stringify(opsOf(q, "select"));
    expect(select).not.toContain("portal_token_hash");
    expect(select).not.toContain("private_note");
    expect(select).toContain("agreed_price::text"); // money never as a float

    // the reader is asked for live sessions only
    expect(fake.rpcs[0]!.args.p_session_ids).toEqual([S2, S1]);
    const appRows = fake.accessLogRows;
    expect(appRows).toEqual([expect.objectContaining({ bride_id: B1, resource: "bride_card", action: "read" })]);
    expect(appRows[0]!.request_id).toBe(fake.rpcs[0]!.args.p_request_id);
  });

  it("is null, with no log row, for an id that is not hers or not a uuid", async () => {
    fake.respond("bride", { data: null });
    await expect(getBrideCard(OTHER)).resolves.toBeNull();
    await expect(getBrideCard("../../etc")).resolves.toBeNull();
    expect(fake.accessLogRows).toHaveLength(0);
    expect(fake.rpcs).toHaveLength(0);
  });
});

describe("createBride", () => {
  it("normalises the phone to E.164 and logs the create", async () => {
    fake.respond("bride", { data: { id: B1 } });
    await expect(
      createBride({ firstName: " נועה ", phone: "050-123-4567", weddingDate: "2027-01-01" as never }),
    ).resolves.toEqual({ ok: true, value: { id: B1 } });
    const insert = opsOf(fake.dataQueries[0]!, "insert")[0]![0] as Record<string, unknown>;
    expect(insert).toMatchObject({ tenant_id: TENANT, first_name: "נועה", phone: "+972501234567" });
    expect(fake.accessLogRows).toEqual([expect.objectContaining({ bride_id: B1, action: "create", resource: "bride" })]);
  });

  it("never forwards a client-supplied id (security review of #55)", async () => {
    // @ts-expect-error — NewBride has no id; the type forbids it.
    const typed: NewBride = { firstName: "x", id: OTHER };
    void typed;

    fake.respond("bride", { data: { id: B1 } });
    await createBride({ firstName: "נועה", id: OTHER, tenant_id: OTHER } as unknown as NewBride);
    const insert = opsOf(fake.dataQueries[0]!, "insert")[0]![0] as Record<string, unknown>;
    expect(insert).not.toHaveProperty("id");
    expect(insert.tenant_id).toBe(TENANT);
    expect(JSON.stringify(insert)).not.toContain(OTHER);
  });

  it("reports her own invalid fields and writes nothing", async () => {
    await expect(createBride({ firstName: "  ", phone: "abc", weddingDate: "2027-02-30" as never })).resolves.toEqual({
      ok: false,
      invalid: ["firstName", "phone", "weddingDate"],
    });
    expect(fake.queries).toHaveLength(0);
  });

  it("surfaces a database error without its message", async () => {
    fake.respond("bride", { error: { code: "23505", message: "Key (phone)=(+972501234567) already exists" } });
    const err = (await createBride({ firstName: "x" }).catch((e: unknown) => e)) as Error;
    expect(err).toMatchObject({ name: "DataAccessError", code: "23505" });
    expect(err.message).not.toContain("972");
  });
});
