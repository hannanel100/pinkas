/**
 * `Secret<T>` — a value that is a credential and must never be printed.
 *
 * An OTP code today; a portal token when #53/#54 land. The failure this guards
 * against is not a deliberate leak but an incidental one: a value interpolated
 * into an error message, serialised into a log line by `JSON.stringify`, dumped
 * by `console.log` / `util.inspect` in a stack trace, or handed to the client
 * as part of a Server Action's return value.
 *
 * * The value lives in an ECMAScript private field, which no reflection,
 *   enumeration, `JSON.stringify` or `util.inspect` can see.
 * * `toString`, `toJSON` and Node's inspect hook all return a fixed marker.
 * * The only way out is `reveal()`, a word that is easy to grep for and easy to
 *   question in review. Call it at the last possible moment, at the one call
 *   site that hands the value to its consumer, and never store the result.
 * * Instances are class instances, which React refuses to serialise across the
 *   server/client boundary — returning one from a Server Action fails loudly.
 *
 * This module does no I/O and imports nothing, so it is safe anywhere on the
 * server. It exports no data-access function, which is why the brand test in
 * `lib/data/brand.test.ts` lists it as infrastructure.
 */

const MARKER = "[secret]";
const INSPECT = Symbol.for("nodejs.util.inspect.custom");

export class Secret<T> {
  readonly #value: T;

  constructor(value: T) {
    this.#value = value;
    Object.freeze(this);
  }

  /** The value. Every call site of this method is a place a credential is used. */
  reveal(): T {
    return this.#value;
  }

  toString(): string {
    return MARKER;
  }

  toJSON(): string {
    return MARKER;
  }

  [Symbol.toPrimitive](): string {
    return MARKER;
  }

  [INSPECT](): string {
    return `Secret(${MARKER})`;
  }
}

export function secret<T>(value: T): Secret<T> {
  return new Secret(value);
}
