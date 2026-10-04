/**
 * Identifiers, validated. Pure — no I/O.
 *
 * `access_log` holds identifiers and actions, never content (SDD §3.11). A
 * string typed "id" is a slot free text can occupy; a `Uuid` cannot be
 * constructed from anything but the canonical 8-4-4-4-12 hex form. Every id
 * that reaches the log, or a query filter, goes through `parseUuid` first.
 */

declare const uuidBrand: unique symbol;
export type Uuid = string & { readonly [uuidBrand]: true };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Lower-cased canonical uuid, or `null`. Never throws, never echoes input. */
export function parseUuid(value: unknown): Uuid | null {
  if (typeof value !== "string" || !UUID.test(value)) return null;
  return value.toLowerCase() as Uuid;
}

export function isUuid(value: unknown): value is Uuid {
  return parseUuid(value) !== null;
}

/** A fresh v4 uuid from the platform CSPRNG. */
export function newUuid(): Uuid {
  return crypto.randomUUID() as Uuid;
}
