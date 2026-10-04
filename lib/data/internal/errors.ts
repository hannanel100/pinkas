/**
 * The errors `lib/data/` throws. Pure — no I/O.
 *
 * None of them carries a value from the request or the database. A Postgres
 * error message can quote the row that violated a constraint — `Key (phone)=
 * (+97250…) already exists` — and a PostgREST `details` field can quote more.
 * Those strings would travel into server logs, error trackers and stack traces,
 * which are exactly the places nobody thought to protect (SDD §3.11, §16). So
 * a database failure is reduced to an operation name the code chose and the
 * SQLSTATE code, and nothing else.
 */

/** No verified session, or a token that is not an instructor's. */
export class NotAuthenticatedError extends Error {
  override readonly name = "NotAuthenticatedError";
  constructor() {
    super("Not authenticated.");
  }
}

/**
 * The session carries an `impersonated_by` claim and was presented to the
 * instructor path (SDD §16.2). Refused outright — never downgraded, never
 * logged as the instructor: a support read recorded as hers is the exact
 * misattribution §16.2 forbids.
 */
export class ImpersonationRefusedError extends Error {
  override readonly name = "ImpersonationRefusedError";
  constructor() {
    super("Impersonated sessions are refused on the instructor path.");
  }
}

/** A database call failed. `operation` is a code-chosen literal. */
export class DataAccessError extends Error {
  override readonly name = "DataAccessError";
  readonly operation: string;
  readonly code: string | null;
  constructor(operation: string, code?: string | null) {
    super(`${operation} failed${code ? ` (${code})` : ""}.`);
    this.operation = operation;
    this.code = code ?? null;
  }
}

/**
 * The audit discipline was broken by the code, not the user: a `per-bride`
 * read returned data and declared no subject, or `logAccess` was handed
 * something that is not an identifier. Always a bug; never caught.
 */
export class AuditViolationError extends Error {
  override readonly name = "AuditViolationError";
}

type PostgrestErrorLike = { code?: unknown } | null | undefined;

/** Throws a `DataAccessError` carrying the SQLSTATE only. */
export function fail(operation: string, error: PostgrestErrorLike): never {
  const code = error && typeof error.code === "string" ? error.code : null;
  throw new DataAccessError(operation, code);
}
