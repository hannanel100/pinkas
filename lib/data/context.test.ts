import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  AuditViolationError,
  ImpersonationRefusedError,
  NotAuthenticatedError,
  auditDescriptorOf,
  defineMutation,
  defineRead,
  requestPhoneOtp,
  signOut,
  verifyPhoneOtp,
} from "./context";
import { secret } from "./secret";
import { ENGINEER, FakeClient, GRANT, TENANT, UUID_RE } from "./testing/fake-client";

const state = vi.hoisted(() => ({ client: undefined as unknown }));
vi.mock("@/lib/supabase/user", () => ({
  createUserClient: async () => state.client,
}));

const BRIDE_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const BRIDE_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

let fake: FakeClient;
beforeEach(() => {
  fake = new FakeClient();
  state.client = fake;
});
afterEach(() => {
  vi.useRealTimers();
});

const readTwo = defineRead(
  { resource: "bride", subjects: "per-bride" },
  async (ctx, ids: readonly string[]) => {
    ctx.subject(...ids);
    return ids.map((id) => ({ id }));
  },
);

const forgetsToSubject = defineRead(
  { resource: "bride", subjects: "per-bride" },
  async (ctx) => {
    await ctx.db.from("bride").select("id");
    return [{ id: BRIDE_A }];
  },
);

const emptyPerBride = defineRead(
  { resource: "bride", subjects: "per-bride" },
  async () => [] as { id: string }[],
);

describe("resolver — requireInstructorContext", () => {
  it("refuses a request with no verified session before any query", async () => {
    fake.claims = null;
    await expect(readTwo([BRIDE_A])).rejects.toBeInstanceOf(NotAuthenticatedError);
    expect(fake.queries).toHaveLength(0);
  });

  it("refuses a non-authenticated role", async () => {
    fake.claims = { sub: TENANT, role: "anon" };
    await expect(readTwo([BRIDE_A])).rejects.toBeInstanceOf(NotAuthenticatedError);
  });

  it("refuses a sub that is not a uuid", async () => {
    fake.claims = { sub: "admin", role: "authenticated" };
    await expect(readTwo([BRIDE_A])).rejects.toBeInstanceOf(NotAuthenticatedError);
  });

  it("refuses any session carrying impersonated_by — fail closed, nothing logged (SDD §16.2)", async () => {
    fake.claims = { sub: TENANT, role: "authenticated", impersonated_by: ENGINEER, support_grant_id: GRANT };
    await expect(readTwo([BRIDE_A])).rejects.toBeInstanceOf(ImpersonationRefusedError);
    expect(fake.queries).toHaveLength(0);
    expect(fake.rpcs).toHaveLength(0);
  });

  it("refuses impersonated_by even when its value is junk", async () => {
    fake.claims = { sub: TENANT, role: "authenticated", impersonated_by: null };
    await expect(readTwo([BRIDE_A])).rejects.toBeInstanceOf(ImpersonationRefusedError);
  });
});

describe("resolver — support audience", () => {
  const supportRead = defineRead(
    { resource: "bride", subjects: "per-bride", audience: "support" },
    async (ctx, id: string) => {
      ctx.subject(id);
      return { id };
    },
  );

  it("logs a support read as support, attributed to the engineer", async () => {
    fake.claims = { sub: TENANT, role: "authenticated", impersonated_by: ENGINEER, support_grant_id: GRANT };
    await supportRead(BRIDE_A);
    expect(fake.accessLogRows).toEqual([
      expect.objectContaining({ tenant_id: TENANT, actor_kind: "support", actor_id: ENGINEER, bride_id: BRIDE_A }),
    ]);
  });

  it("refuses a support session with no grant id", async () => {
    fake.claims = { sub: TENANT, role: "authenticated", impersonated_by: ENGINEER };
    await expect(supportRead(BRIDE_A)).rejects.toBeInstanceOf(NotAuthenticatedError);
  });

  it("refuses an ordinary instructor session", async () => {
    await expect(supportRead(BRIDE_A)).rejects.toBeInstanceOf(NotAuthenticatedError);
  });
});

describe("defineRead — per-bride", () => {
  it("fans out one access_log row per distinct bride, sharing one uuid request id", async () => {
    const result = await readTwo([BRIDE_A, BRIDE_B, BRIDE_A]);
    expect(result).toHaveLength(3);
    const rows = fake.accessLogRows;
    expect(rows.map((r) => r.bride_id)).toEqual([BRIDE_A, BRIDE_B]);
    const requestIds = new Set(rows.map((r) => r.request_id));
    expect(requestIds.size).toBe(1);
    expect([...requestIds][0]).toMatch(UUID_RE);
    for (const row of rows) {
      expect(row).toEqual({
        tenant_id: TENANT,
        actor_kind: "instructor",
        actor_id: TENANT,
        bride_id: expect.any(String),
        action: "read",
        resource: "bride",
        request_id: expect.any(String),
      });
    }
  });

  it("uses a fresh request id per call", async () => {
    await readTwo([BRIDE_A]);
    await readTwo([BRIDE_A]);
    const ids = fake.accessLogRows.map((r) => r.request_id);
    expect(ids[0]).not.toEqual(ids[1]);
  });

  it("throws, and returns nothing, when data came back and nobody was subjected", async () => {
    await expect(forgetsToSubject()).rejects.toBeInstanceOf(AuditViolationError);
    expect(fake.accessLogRows).toHaveLength(0);
  });

  it("writes no row for an empty result — nothing was disclosed", async () => {
    await expect(emptyPerBride()).resolves.toEqual([]);
    expect(fake.queries.filter((q) => q.table === "access_log")).toHaveLength(0);
  });

  it("refuses a subject that is not a uuid — no free text reaches the log", async () => {
    await expect(readTwo(["Noa is pregnant"])).rejects.toBeInstanceOf(AuditViolationError);
    expect(fake.accessLogRows).toHaveLength(0);
  });

  it("does not return data if the log write fails", async () => {
    fake.respond("access_log", { error: { code: "42501" } });
    await expect(readTwo([BRIDE_A])).rejects.toMatchObject({ name: "DataAccessError", code: "42501" });
  });
});

describe("defineRead — none and database", () => {
  const settings = defineRead({ resource: "instructor", subjects: "none" }, async (ctx) => {
    // @ts-expect-error — under "none" there is no ctx.subject.
    void ctx.subject;
    return { tenant: ctx.tenantId };
  });

  const selfLogging = defineRead(
    { resource: "today_screen", subjects: "database" },
    async (ctx) => {
      // @ts-expect-error — under "database" there is no client for an unlogged query.
      void ctx.db;
      return ctx.loggedRpc("today_screen", { p_today: ctx.today });
    },
  );

  it("'none' writes no access_log row", async () => {
    await expect(settings()).resolves.toEqual({ tenant: TENANT });
    expect(fake.queries).toHaveLength(0);
  });

  it("'database' calls the RPC with an injected uuid request id and writes nothing itself", async () => {
    fake.respondRpc("today_screen", { data: { ok: 1 } });
    await expect(selfLogging()).resolves.toEqual({ ok: 1 });
    expect(fake.rpcs).toHaveLength(1);
    expect(fake.rpcs[0]!.args.p_request_id).toMatch(UUID_RE);
    expect(fake.queries).toHaveLength(0);
  });

  it("'database' surfaces an RPC error as a DataAccessError with the SQLSTATE only", async () => {
    fake.respondRpc("today_screen", { error: { code: "22023", message: "contains Noa" } });
    const err = (await selfLogging().catch((e: unknown) => e)) as Error;
    expect(err).toMatchObject({ name: "DataAccessError", code: "22023" });
    expect(String(err.message)).not.toContain("Noa");
  });
});

describe("today is injected from the Israeli civil date", () => {
  it("is tomorrow in Jerusalem while still today in UTC", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-04T22:30:00Z")); // 01:30 IDT on the 5th
    const read = defineRead({ resource: "instructor", subjects: "none" }, async (ctx) => ctx.today);
    await expect(read()).resolves.toBe("2026-10-05");
  });
});

describe("the brand", () => {
  it("carries the descriptor on every defined function", () => {
    expect(auditDescriptorOf(readTwo)).toEqual({
      kind: "read",
      resource: "bride",
      subjects: "per-bride",
      audience: "instructor",
    });
    const m = defineMutation(
      { resource: "bride", action: "create", subjects: "per-bride" },
      async () => null,
    );
    expect(auditDescriptorOf(m)?.kind).toBe("mutation");
    expect(auditDescriptorOf(async () => null)).toBeNull();
  });
});

describe("sign-in — no reason on failure", () => {
  it("rejects a malformed phone without calling Auth", async () => {
    await expect(requestPhoneOtp("not a phone")).resolves.toStrictEqual({ ok: false });
    expect(fake.authCalls).toHaveLength(0);
  });

  it("requests the code for the E.164 form", async () => {
    await expect(requestPhoneOtp("050-123-4567")).resolves.toStrictEqual({ ok: true, value: undefined });
    expect(fake.authCalls[0]).toEqual([
      "signInWithOtp",
      { phone: "+972501234567", options: { shouldCreateUser: true, channel: "sms" } },
    ]);
  });

  it("an Auth failure is a bare { ok: false }", async () => {
    fake.authError = { message: "Invalid phone or code; user does not exist" };
    await expect(requestPhoneOtp("0501234567")).resolves.toStrictEqual({ ok: false });
    await expect(verifyPhoneOtp("0501234567", secret("123456"))).resolves.toStrictEqual({ ok: false });
  });

  it("verifies with the revealed code and the E.164 phone", async () => {
    await expect(verifyPhoneOtp("+972 50 123 4567", secret("123456"))).resolves.toStrictEqual({
      ok: true,
      value: undefined,
    });
    expect(fake.authCalls[0]).toEqual(["verifyOtp", { phone: "+972501234567", token: "123456", type: "sms" }]);
  });

  it("rejects a non-numeric code without calling Auth", async () => {
    await expect(verifyPhoneOtp("0501234567", secret("12ab56"))).resolves.toStrictEqual({ ok: false });
    expect(fake.authCalls).toHaveLength(0);
  });

  it("signs out this device only", async () => {
    await signOut();
    expect(fake.authCalls).toEqual([["signOut", { scope: "local" }]]);
  });
});
