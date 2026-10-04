import { beforeEach, describe, expect, it, vi } from "vitest";

import { bootstrapInstructor } from "./instructor";
import { normalisePhoneE164 } from "./internal/phone";
import { FakeClient, TENANT } from "./testing/fake-client";

const state = vi.hoisted(() => ({ client: undefined as unknown }));
vi.mock("@/lib/supabase/user", () => ({ createUserClient: async () => state.client }));

let fake: FakeClient;
beforeEach(() => {
  fake = new FakeClient();
  state.client = fake;
});

const templates = [{ name: "reminder", body: "שלום {{bride_name}}" }];

describe("bootstrapInstructor", () => {
  it("calls bootstrap_instructor with E.164 phone and no tenant parameter; writes no log row", async () => {
    fake.respondRpc("bootstrap_instructor", {
      data: [{ instructor_id: TENANT, was_created: true, seeded_curriculum_id: null, seeded_template_count: 1 }],
    });
    await expect(
      bootstrapInstructor({ fullName: " רבקה ", phone: "054-765-4321", templates }),
    ).resolves.toEqual({ ok: true, value: { instructorId: TENANT, wasCreated: true } });
    expect(fake.rpcs[0]).toEqual({
      name: "bootstrap_instructor",
      args: { p_full_name: "רבקה", p_phone: "+972547654321", p_templates: templates, p_email: null, p_curriculum: null },
    });
    expect(fake.queries).toHaveLength(0);
  });

  it("refuses an empty template list (D1 must work from day one)", async () => {
    await expect(bootstrapInstructor({ fullName: "x", phone: "0547654321", templates: [] })).resolves.toEqual({
      ok: false,
      invalid: ["templates"],
    });
    expect(fake.rpcs).toHaveLength(0);
  });

  it("fails if the function reports a tenant other than the caller", async () => {
    fake.respondRpc("bootstrap_instructor", {
      data: [{ instructor_id: "99999999-9999-4999-8999-999999999999", was_created: true }],
    });
    await expect(bootstrapInstructor({ fullName: "x", phone: "0547654321", templates })).rejects.toMatchObject({
      name: "DataAccessError",
    });
  });
});

describe("normalisePhoneE164 (SDD §14.1)", () => {
  it.each([
    ["050-123-4567", "+972501234567"],
    ["0501234567", "+972501234567"],
    ["+972 50 123 4567", "+972501234567"],
    ["972501234567", "+972501234567"],
    ["00972501234567", "+972501234567"],
    ["+972-050-1234567", "+972501234567"],
    ["(03) 123-4567", "+97231234567"],
    ["+1 212 555 0100", "+12125550100"],
  ])("%s → %s", (raw, e164) => {
    expect(normalisePhoneE164(raw)).toBe(e164);
  });

  it.each(["", "abc", "050-123", "12345", "+0501234567", "05012345678901", "050 123 4567 ext 2"])(
    "rejects %j",
    (raw) => {
      expect(normalisePhoneE164(raw)).toBeNull();
    },
  );
});
