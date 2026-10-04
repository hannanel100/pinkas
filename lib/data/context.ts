import "server-only";

import type { CalendarDate } from "@/lib/domain/hebrew-calendar";
import { createUserClient, type UserClient } from "@/lib/supabase/user";

import {
  logAccess,
  type AccessResource,
  type Actor,
  type RequestId,
} from "./audit";
import { jerusalemToday } from "./internal/clock";
import {
  AuditViolationError,
  ImpersonationRefusedError,
  NotAuthenticatedError,
  fail,
} from "./internal/errors";
import { newUuid, parseUuid, type Uuid } from "./internal/ids";
import { normalisePhoneE164 } from "./internal/phone";
import type { Secret } from "./secret";

/**
 * The request context, and the only way to obtain a database client on the
 * instructor path. SDD §13, ADR-0006, ADR-0009; settled in #7's design
 * challenge.
 *
 * ── Why this module exists ─────────────────────────────────────────────────
 *
 * The access log is complete only because every read happens in one place
 * (Postgres has no `AFTER SELECT`). "Every exported function calls logAccess"
 * is a discipline; this module turns it into a structure:
 *
 * * It is the **sole importer** of `lib/supabase/user` (lint-enforced). It
 *   exports neither the client factory nor a context constructor. The only way
 *   to get a client is to be the body of `defineRead` / `defineMutation`, and
 *   those wrappers write the log before handing the result back.
 * * Every function they return carries the `AUDITED` brand.
 *   `lib/data/brand.test.ts` imports every module in `lib/data/` and fails CI
 *   on any exported function without it — the test fails by the export's mere
 *   existence, before anyone calls it.
 * * The actor is a **source literal in the resolver** — `"instructor"` below —
 *   never a parameter a caller supplies.
 *
 * ── Subjects: "per-bride" | "none" | "database" ────────────────────────────
 *
 * * `"per-bride"` — the body calls `ctx.subject(brideId)` for every bride
 *   whose data it returns or changes; the wrapper fans out one `access_log` row
 *   per bride. If the body returns a non-empty result and declared nobody, the
 *   wrapper throws and the data is not returned. What it cannot catch is
 *   "subjected three of the five brides returned" — the per-function tests
 *   catch that, and nothing here pretends otherwise.
 * * `"none"` — touches no bride data (her own profile, templates, signup).
 *   `ctx.subject` does not exist on the type, and no row is written: the log
 *   is a log of access to brides, the same reading migration 0002 takes.
 * * `"database"` — the body may call only the self-logging RPCs
 *   (`today_screen`, `read_session_records`), which write their `access_log`
 *   rows in the same statement as the read. The context has **no `db`**, so
 *   such a body cannot issue an unlogged query; and `p_request_id` is injected
 *   by `loggedRpc`, never by the body.
 *
 * ── Impersonation (SDD §16.2) ──────────────────────────────────────────────
 *
 * The instructor resolver refuses any session carrying `impersonated_by` —
 * fail closed, no fallback. The support resolver requires that claim plus a
 * `support_grant_id`. As §16.2 says plainly, this binds only tooling we build:
 * a holder of the service key can mint a session without the claim. What
 * holds against that insider is the column revoke of ADR-0009.
 */

/* ── Results ─────────────────────────────────────────────────────────────── */

/**
 * `{ ok: false }` carries no reason. "Not found", "another tenant's" and "not in
 * a state that allows this" are indistinguishable to the caller, by design —
 * RLS makes the first two identical anyway, and a reason field is where a
 * leak would be added later.
 */
export type Result<T> = { readonly ok: true; readonly value: T } | { readonly ok: false };

/**
 * For instructor forms only: which of HER OWN fields failed validation. Names
 * input fields, never database state.
 */
export type FormResult<T, F extends string> =
  | Result<T>
  | { readonly ok: false; readonly invalid: readonly F[] };

export function ok<T>(value: T): { readonly ok: true; readonly value: T } {
  return { ok: true, value };
}
export const notOk = Object.freeze({ ok: false } as const);

/* ── Contexts ────────────────────────────────────────────────────────────── */

export type Subjects = "per-bride" | "none" | "database";
type Audience = "instructor" | "support";

/** RPCs that write their own `access_log` rows in the same statement. */
type SelfLoggingRpcs = {
  /** Migration 0004. */
  readonly today_screen: { readonly p_today: string };
  /** Migration 0006. */
  readonly read_session_records: { readonly p_session_ids: readonly string[] };
};
export type SelfLoggingRpc = keyof SelfLoggingRpcs;

/**
 * The runtime twin of `SelfLoggingRpcs`. The type alone can be cast away —
 * `(ctx.loggedRpc as any)("other_rpc")` would otherwise call an RPC that logs
 * nothing, from a context that writes nothing (#60 review).
 */
const SELF_LOGGING_RPCS: ReadonlySet<string> = new Set<SelfLoggingRpc>([
  "today_screen",
  "read_session_records",
]);

/**
 * Resources that may be declared `subjects: "none"` — i.e. that disclose no
 * bride's data and so write no log row. A closed list, checked when the
 * function is DEFINED, so a `"none"` read of `bride` fails at import time
 * rather than quietly returning brides unlogged (#60 review).
 */
const NO_SUBJECT_RESOURCES: ReadonlySet<AccessResource> = new Set<AccessResource>([
  "instructor",
]);

/**
 * The only database calls a `"none"` body can make (#60 re-review). Declaring
 * `resource: "instructor"` is a label, and a label is not a control: given a
 * general client, a `"none"` body could read `bride` and log nothing. So it
 * gets no client — only `ctx.rpc`, checked at runtime against this list, of
 * functions that run under RLS and return no bride's data.
 *
 * Widening this list is a decision about the access log, and should be made
 * as one: a function that returns bride data does not belong here.
 */
export type NoSubjectRpcs = {
  /** Migration 0002 — the signup seed; returns the caller's own ids. */
  readonly bootstrap_instructor: Readonly<Record<string, unknown>>;
};
const NO_SUBJECT_RPCS: ReadonlySet<string> = new Set<keyof NoSubjectRpcs>([
  "bootstrap_instructor",
]);

type RpcResult = { readonly data: unknown; readonly error: { readonly code?: string } | null };

type BaseContext = {
  readonly tenantId: Uuid;
  readonly actor: Actor;
  /** Shared by every `access_log` row this call writes, in-app or in-database. */
  readonly requestId: RequestId;
  /** Today in Asia/Jerusalem, read once per call and injected (invariant 4). */
  readonly today: CalendarDate;
  /** Calls a self-logging RPC with this call's request id. */
  loggedRpc<K extends SelfLoggingRpc>(name: K, args: SelfLoggingRpcs[K]): Promise<unknown>;
};

export type DatabaseLoggedContext = BaseContext;
/** No client — `rpc` reaches the `NO_SUBJECT_RPCS` allowlist and nothing else. */
export type NoSubjectContext = BaseContext & {
  rpc<K extends keyof NoSubjectRpcs>(name: K, args: NoSubjectRpcs[K]): Promise<RpcResult>;
};
export type PerBrideContext = BaseContext & {
  readonly db: UserClient;
  /** Declares the brides whose data this call disclosed or changed. */
  subject(...brideIds: readonly unknown[]): void;
};

type ContextFor<S extends Subjects> = S extends "per-bride"
  ? PerBrideContext
  : S extends "none"
    ? NoSubjectContext
    : DatabaseLoggedContext;

/* ── The brand ───────────────────────────────────────────────────────────── */

const AUDITED = Symbol.for("pinkas.lib.data.audited");

export type AuditDescriptor = {
  readonly kind: "read" | "mutation";
  readonly resource: AccessResource;
  readonly subjects: Subjects;
  readonly audience: Audience;
};

export type Audited<A extends readonly unknown[], R> = ((...args: A) => Promise<R>) & {
  readonly [AUDITED]: AuditDescriptor;
};

/** For `brand.test.ts`: the descriptor, or `null` for an unaudited function. */
export function auditDescriptorOf(fn: unknown): AuditDescriptor | null {
  if (typeof fn !== "function") return null;
  const d = (fn as { [AUDITED]?: unknown })[AUDITED];
  return d && typeof d === "object" ? (d as AuditDescriptor) : null;
}

/* ── Resolvers ───────────────────────────────────────────────────────────── */

type Resolved = { db: UserClient; tenantId: Uuid; actor: Actor };

/** Verified claims, or `null`. `getClaims` checks the signature (JWKS) or asks Auth. */
async function verifiedClaims(db: UserClient): Promise<Record<string, unknown> | null> {
  const { data, error } = await db.auth.getClaims();
  if (error || !data || typeof data.claims !== "object" || data.claims === null) {
    return null;
  }
  return data.claims as Record<string, unknown>;
}

/**
 * `impersonated_by` anywhere a support tool could put it: top level (a minted
 * token or the access-token hook, ADR-0010 §4), or inside `app_metadata` /
 * `user_metadata` (what `raw_app_meta_data` / `raw_user_meta_data` become in
 * the JWT). Any of the three refuses the instructor path — a support read
 * logged as hers is the misattribution SDD §16.2 forbids. An instructor who
 * writes the key into her own `user_metadata` only locks herself out.
 */
function carriesImpersonation(claims: Record<string, unknown>): boolean {
  if ("impersonated_by" in claims) return true;
  for (const key of ["app_metadata", "user_metadata"] as const) {
    const nested = claims[key];
    if (nested !== null && typeof nested === "object" && "impersonated_by" in nested) {
      return true;
    }
  }
  return false;
}

async function requireInstructorContext(): Promise<Resolved> {
  const db = await createUserClient();
  const claims = await verifiedClaims(db);
  if (!claims || claims.role !== "authenticated") throw new NotAuthenticatedError();
  if (carriesImpersonation(claims)) throw new ImpersonationRefusedError();
  const tenantId = parseUuid(claims.sub);
  if (!tenantId) throw new NotAuthenticatedError();
  return { db, tenantId, actor: { kind: "instructor", id: tenantId } };
}

async function requireSupportContext(): Promise<Resolved> {
  const db = await createUserClient();
  const claims = await verifiedClaims(db);
  if (!claims || claims.role !== "authenticated") throw new NotAuthenticatedError();
  const tenantId = parseUuid(claims.sub);
  const engineer = parseUuid(claims.impersonated_by);
  const grantId = parseUuid(claims.support_grant_id);
  if (!tenantId || !engineer || !grantId) throw new NotAuthenticatedError();
  return { db, tenantId, actor: { kind: "support", id: engineer, grantId } };
}

function resolve(audience: Audience): Promise<Resolved> {
  return audience === "support" ? requireSupportContext() : requireInstructorContext();
}

/* ── Building a context ──────────────────────────────────────────────────── */

function makeLoggedRpc(db: UserClient, requestId: RequestId): BaseContext["loggedRpc"] {
  return async (name, args) => {
    if (!SELF_LOGGING_RPCS.has(name)) {
      throw new AuditViolationError("loggedRpc: not a self-logging RPC.");
    }
    const { data, error } = await db.rpc(name, { ...args, p_request_id: requestId });
    if (error) fail(`rpc.${name}`, error);
    return data;
  };
}

function isEmptyResult(value: unknown): boolean {
  if (value === null || value === undefined) return true;
  if (Array.isArray(value)) return value.length === 0;
  if (typeof value === "object" && (value as { ok?: unknown }).ok === false) return true;
  return false;
}

type Descriptor<S extends Subjects> = {
  readonly resource: AccessResource;
  readonly subjects: S;
  /** Defaults to `"instructor"`. Nothing in Phase 1 declares `"support"` yet. */
  readonly audience?: Audience;
};

function wrap<S extends Subjects, A extends readonly unknown[], R>(
  kind: "read" | "mutation",
  action: "read" | "create" | "update",
  descriptor: Descriptor<S>,
  body: (ctx: ContextFor<S>, ...args: A) => Promise<R>,
): Audited<A, R> {
  const audience: Audience = descriptor.audience ?? "instructor";
  const { resource, subjects } = descriptor;
  if (subjects === "none" && !NO_SUBJECT_RESOURCES.has(resource)) {
    throw new AuditViolationError(`${resource}: may not be declared subjects "none".`);
  }

  const fn = async (...args: A): Promise<R> => {
    const { db, tenantId, actor } = await resolve(audience);
    const requestId = newUuid() as RequestId;
    const subjected = new Set<Uuid>();
    const base: BaseContext = {
      tenantId,
      actor,
      requestId,
      today: jerusalemToday(),
      loggedRpc: makeLoggedRpc(db, requestId),
    };

    let ctx: DatabaseLoggedContext | NoSubjectContext | PerBrideContext;
    if (subjects === "database") {
      ctx = base;
    } else if (subjects === "none") {
      ctx = {
        ...base,
        async rpc(name: string, args: Readonly<Record<string, unknown>>): Promise<RpcResult> {
          if (!NO_SUBJECT_RPCS.has(name)) {
            throw new AuditViolationError("rpc: not allowed for a subjects \"none\" function.");
          }
          const { data, error } = await db.rpc(name, args);
          return { data, error };
        },
      } satisfies NoSubjectContext;
    } else {
      ctx = {
        ...base,
        db,
        subject(...ids: readonly unknown[]) {
          for (const raw of ids) {
            const id = parseUuid(raw);
            if (!id) throw new AuditViolationError("subject: not a bride id.");
            subjected.add(id);
          }
        },
      } satisfies PerBrideContext;
    }

    const result = await body(ctx as ContextFor<S>, ...args);

    if (subjects === "per-bride") {
      if (subjected.size === 0 && !isEmptyResult(result)) {
        throw new AuditViolationError(
          `${resource}: declared per-bride, returned data, subjected nobody.`,
        );
      }
      await logAccess(db, {
        tenantId,
        actor,
        brideIds: [...subjected],
        action,
        resource,
        requestId,
      });
    }
    return result;
  };

  const audited: AuditDescriptor = Object.freeze({ kind, resource, subjects, audience });
  Object.defineProperty(fn, AUDITED, { value: audited, enumerable: false });
  return fn as Audited<A, R>;
}

/**
 * Defines an audited read. The body receives a context and returns the result;
 * the wrapper writes the log, and only then returns.
 */
export function defineRead<S extends Subjects, A extends readonly unknown[], R>(
  descriptor: Descriptor<S>,
  body: (ctx: ContextFor<S>, ...args: A) => Promise<R>,
): Audited<A, R> {
  return wrap("read", "read", descriptor, body);
}

/**
 * Defines an audited write. Writes are logged too: a mutation's response
 * discloses the row it touched. `"database"` subjects are not offered — no
 * self-logging RPC writes.
 */
export function defineMutation<
  S extends "per-bride" | "none",
  A extends readonly unknown[],
  R,
>(
  descriptor: Descriptor<S> & { readonly action: "create" | "update" },
  body: (ctx: ContextFor<S>, ...args: A) => Promise<R>,
): Audited<A, R> {
  return wrap("mutation", descriptor.action, descriptor, body);
}

/* ── Sign-in (SDD §6.1) ──────────────────────────────────────────────────── */
//
// These live here because this is the only module that may construct the
// user client, and they never hand it out. They touch Auth, not bride data, so
// they write no access_log row. The Server Actions, screens, route protection,
// OTP rate limiting and email fallback that call them are #10.
//
// Every failure is `{ ok: false }` with no reason: "no such phone", "wrong
// code" and "expired code" must be indistinguishable to whoever is guessing.

const OTP_CODE = /^\d{4,10}$/;

/** Sends an SMS code. Creates the auth user on first use (A1 — no email step). */
export async function requestPhoneOtp(phone: string): Promise<Result<void>> {
  const e164 = normalisePhoneE164(phone);
  if (!e164) return notOk;
  const db = await createUserClient();
  const { error } = await db.auth.signInWithOtp({
    phone: e164,
    options: { shouldCreateUser: true, channel: "sms" },
  });
  return error ? notOk : ok(undefined);
}

/**
 * Verifies the code; on success the session cookie is written with the flags
 * in `lib/supabase/user.ts`. Call from a Server Action or Route Handler, never
 * from a render. Provisioning the tenant is `bootstrapInstructor` in
 * `instructor.ts`, called next.
 */
export async function verifyPhoneOtp(
  phone: string,
  code: Secret<string>,
): Promise<Result<void>> {
  const e164 = normalisePhoneE164(phone);
  const token = code.reveal();
  if (!e164 || !OTP_CODE.test(token)) return notOk;
  const db = await createUserClient();
  const { data, error } = await db.auth.verifyOtp({ phone: e164, token, type: "sms" });
  return error || !data.session ? notOk : ok(undefined);
}

/** Ends this device's session and clears the cookie. */
export async function signOut(): Promise<void> {
  const db = await createUserClient();
  await db.auth.signOut({ scope: "local" });
}

export {
  AuditViolationError,
  DataAccessError,
  ImpersonationRefusedError,
  NotAuthenticatedError,
} from "./internal/errors";
