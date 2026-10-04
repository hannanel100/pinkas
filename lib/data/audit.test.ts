import { describe, expect, it } from "vitest";

import { logAccess, type AccessEvent, type RequestId } from "./audit";
import type { Uuid } from "./internal/ids";
import { ENGINEER, FakeClient, GRANT, TENANT } from "./testing/fake-client";

const REQ = "cccccccc-cccc-4ccc-8ccc-cccccccccccc" as RequestId;
const A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" as Uuid;

function event(overrides: Partial<AccessEvent> = {}): AccessEvent {
  return {
    tenantId: TENANT as Uuid,
    actor: { kind: "instructor", id: TENANT as Uuid },
    brideIds: [A],
    action: "read",
    resource: "bride",
    requestId: REQ,
    ...overrides,
  };
}

describe("logAccess", () => {
  it("writes exactly the identifier columns — no free-text column exists", async () => {
    const db = new FakeClient();
    await logAccess(db as never, event());
    expect(db.accessLogRows).toEqual([
      {
        tenant_id: TENANT,
        actor_kind: "instructor",
        actor_id: TENANT,
        bride_id: A,
        action: "read",
        resource: "bride",
        request_id: REQ,
      },
    ]);
  });

  it("writes nothing for no brides — never a bride_id = null row", async () => {
    const db = new FakeClient();
    await logAccess(db as never, event({ brideIds: [] }));
    expect(db.queries).toHaveLength(0);
  });

  it("deduplicates and lower-cases bride ids", async () => {
    const db = new FakeClient();
    await logAccess(db as never, event({ brideIds: [A, A.toUpperCase() as Uuid] }));
    expect(db.accessLogRows.map((r) => r.bride_id)).toEqual([A]);
  });

  it.each([
    ["a bride id that is text", { brideIds: ["see notes: pregnant" as Uuid] }],
    ["an unknown action", { action: "export" as never }],
    ["an unknown resource", { resource: "private_note" as never }],
    ["a request id that is text", { requestId: "Noa called" as RequestId }],
    ["an instructor actor who is not the tenant", { actor: { kind: "instructor" as const, id: A } }],
    ["a support actor with no grant", { actor: { kind: "support", id: ENGINEER } as never }],
    ["an unknown actor kind", { actor: { kind: "bride_portal", id: A } as never }],
  ])("refuses %s, writing nothing", async (_label, overrides) => {
    const db = new FakeClient();
    await expect(logAccess(db as never, event(overrides as Partial<AccessEvent>))).rejects.toMatchObject({
      name: "AuditViolationError",
    });
    expect(db.queries).toHaveLength(0);
  });

  it("records a support actor as support, with the engineer as actor_id", async () => {
    const db = new FakeClient();
    await logAccess(
      db as never,
      event({ actor: { kind: "support", id: ENGINEER as Uuid, grantId: GRANT as Uuid } }),
    );
    expect(db.accessLogRows[0]).toMatchObject({ actor_kind: "support", actor_id: ENGINEER });
  });

  it("throws on a failed insert, carrying the SQLSTATE only", async () => {
    const db = new FakeClient().respond("access_log", {
      error: { code: "23514", message: "Failing row contains (… Noa …)" },
    });
    const err = (await logAccess(db as never, event()).catch((e: unknown) => e)) as Error;
    expect(err).toMatchObject({ name: "DataAccessError", code: "23514" });
    expect(err.message).not.toContain("Noa");
  });
});
