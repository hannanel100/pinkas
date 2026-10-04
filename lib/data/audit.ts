import "server-only";

import { AuditViolationError, fail } from "./internal/errors";
import { parseUuid, type Uuid } from "./internal/ids";

/**
 * `logAccess` — the application half of the access log PRD §10.1 requires.
 * SDD §3.11, §13, §16.2; ADR-0006, ADR-0009.
 *
 * Called by the wrappers in `context.ts` and by nothing else: they are the
 * only code holding a client, and every exported data function is one of them.
 *
 * ── What a row says ────────────────────────────────────────────────────────
 *
 * Identifiers and actions, never content. There is deliberately **no
 * free-text slot** in `AccessEvent`: `action` and `resource` are closed
 * literal unions checked again at runtime, every id must parse as a uuid, and
 * `requestId` is a uuid minted by `context.ts`. A note body has no field to
 * occupy, so it cannot end up here by accident or by a well-meaning
 * "add some context to the log" change.
 *
 * ── Fan-out, never null ────────────────────────────────────────────────────
 *
 * One row per DISTINCT bride whose data the call disclosed, all sharing the
 * call's `requestId` — the same shape `today_screen` and
 * `read_session_records` write in-database. A call that disclosed no bride
 * writes no row: the log records what was disclosed, and nothing was. There is
 * never a `bride_id = null` row standing for "some brides".
 *
 * ── Actor ──────────────────────────────────────────────────────────────────
 *
 * The actor is resolved in `context.ts` from the verified JWT, as a source
 * literal per resolver — never a parameter a caller supplies. An instructor
 * row's `actor_id` is the tenant (mirrors `access_log_instructor_actor_ck`,
 * migration 0006); a support row's is the engineer from `impersonated_by`.
 *
 * ── Migration 0009 (#53) ───────────────────────────────────────────────────
 *
 * #53 revokes `INSERT on access_log` from `authenticated` and adds a definer
 * `log_access(bride_ids uuid[], action, resource, request_id uuid)` that takes
 * the actor from the JWT claims. When it lands, `writeAccessLog` below becomes
 *
 *     db.rpc("log_access", { bride_ids, action, resource, request_id })
 *
 * — the argument shape is already exactly that, and nothing else in this
 * layer touches `access_log`. Do not depend on 0009 existing until it does.
 */

export const ACCESS_ACTIONS = ["read", "create", "update"] as const;
export type AccessAction = (typeof ACCESS_ACTIONS)[number];

/**
 * What was accessed, at the granularity a reader of the log needs to answer
 * "who saw what about this bride". `session_record` and `today_screen` are
 * also written in-database by their own functions (migrations 0004, 0006).
 */
export const ACCESS_RESOURCES = [
  "bride",
  "bride_card",
  "instructor",
  "course",
  "schedule",
  "session",
  "session_record",
  "today_screen",
] as const;
export type AccessResource = (typeof ACCESS_RESOURCES)[number];

declare const requestIdBrand: unique symbol;
/** A uuid identifying one data-function call. Minted by `context.ts` only. */
export type RequestId = Uuid & { readonly [requestIdBrand]: true };

export type Actor =
  | { readonly kind: "instructor"; readonly id: Uuid }
  | { readonly kind: "support"; readonly id: Uuid; readonly grantId: Uuid };

export type AccessEvent = {
  readonly tenantId: Uuid;
  readonly actor: Actor;
  readonly brideIds: readonly Uuid[];
  readonly action: AccessAction;
  readonly resource: AccessResource;
  readonly requestId: RequestId;
};

/**
 * The slice of a client `logAccess` needs, structurally — so this module
 * imports no client type and can be handed nothing broader by accident.
 */
type AccessLogWriter = {
  from(relation: "access_log"): {
    insert(rows: readonly object[]): PromiseLike<{ error: { code?: string } | null }>;
  };
};

/**
 * Writes the event's rows, or throws. The caller must not return data to its
 * own caller if this throws — `context.ts` awaits it before returning.
 */
export async function logAccess(
  db: AccessLogWriter,
  event: AccessEvent,
): Promise<void> {
  const checked = validate(event);
  if (checked.brideIds.length === 0) return;
  await writeAccessLog(db, checked);
}

/** Runtime re-check of what the types already say — the types can be cast. */
function validate(event: AccessEvent): AccessEvent {
  const tenantId = parseUuid(event.tenantId);
  const actorId = parseUuid(event.actor?.id);
  const requestId = parseUuid(event.requestId);
  if (!tenantId || !actorId || !requestId) {
    throw new AuditViolationError("access_log: tenant, actor and request must be uuids.");
  }
  if (!(ACCESS_ACTIONS as readonly string[]).includes(event.action)) {
    throw new AuditViolationError("access_log: unknown action.");
  }
  if (!(ACCESS_RESOURCES as readonly string[]).includes(event.resource)) {
    throw new AuditViolationError("access_log: unknown resource.");
  }

  let actor: Actor;
  if (event.actor.kind === "instructor") {
    if (actorId !== tenantId) {
      throw new AuditViolationError("access_log: an instructor actor is the tenant.");
    }
    actor = { kind: "instructor", id: actorId };
  } else if (event.actor.kind === "support") {
    const grantId = parseUuid(event.actor.grantId);
    if (!grantId) throw new AuditViolationError("access_log: support needs a grant.");
    actor = { kind: "support", id: actorId, grantId };
  } else {
    throw new AuditViolationError("access_log: unknown actor kind.");
  }

  const brideIds: Uuid[] = [];
  const seen = new Set<string>();
  for (const raw of event.brideIds) {
    const id = parseUuid(raw);
    if (!id) throw new AuditViolationError("access_log: bride ids must be uuids.");
    if (!seen.has(id)) {
      seen.add(id);
      brideIds.push(id);
    }
  }

  return {
    tenantId,
    actor,
    brideIds,
    action: event.action,
    resource: event.resource,
    requestId: requestId as RequestId,
  };
}

/**
 * The single place a row reaches `access_log`. Swap for `rpc("log_access", …)`
 * when migration 0009 lands (see the module header). `grantId` has no column
 * yet — recorded as a decision for `database`, not silently dropped into a
 * free-text field.
 */
async function writeAccessLog(db: AccessLogWriter, e: AccessEvent): Promise<void> {
  const rows = e.brideIds.map((brideId) => ({
    tenant_id: e.tenantId,
    actor_kind: e.actor.kind,
    actor_id: e.actor.id,
    bride_id: brideId,
    action: e.action,
    resource: e.resource,
    request_id: e.requestId,
  }));
  const { error } = await db.from("access_log").insert(rows);
  if (error) fail("access_log.insert", error);
}
