/**
 * Row-value parsers shared by the `lib/data/` modules. Pure — no I/O.
 *
 * PostgREST rows are untyped here (no generated `Database` type yet), so every
 * module parses at the boundary. A row that does not have the expected shape
 * is a contract break between this layer and the schema, and fails loudly as
 * a `DataAccessError` naming the operation — never with the row's content.
 */

import {
  tryParseCalendarDate,
  type CalendarDate,
} from "@/lib/domain/hebrew-calendar";

import { DataAccessError } from "./errors";
import { parseUuid, type Uuid } from "./ids";

export type Row = Readonly<Record<string, unknown>>;

export function asRow(operation: string, value: unknown): Row {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new DataAccessError(operation, "shape");
  }
  return value as Row;
}

export function asRows(operation: string, value: unknown): readonly Row[] {
  if (!Array.isArray(value)) throw new DataAccessError(operation, "shape");
  return value.map((v) => asRow(operation, v));
}

export function uuidField(operation: string, row: Row, key: string): Uuid {
  const id = parseUuid(row[key]);
  if (id === null) throw new DataAccessError(operation, "shape");
  return id;
}

export function optionalUuidField(
  operation: string,
  row: Row,
  key: string,
): Uuid | null {
  if (row[key] === null || row[key] === undefined) return null;
  return uuidField(operation, row, key);
}

export function stringField(operation: string, row: Row, key: string): string {
  const v = row[key];
  if (typeof v !== "string") throw new DataAccessError(operation, "shape");
  return v;
}

export function optionalStringField(
  operation: string,
  row: Row,
  key: string,
): string | null {
  const v = row[key];
  if (v === null || v === undefined) return null;
  if (typeof v !== "string") throw new DataAccessError(operation, "shape");
  return v;
}

export function intField(operation: string, row: Row, key: string): number {
  const v = row[key];
  const n = typeof v === "string" && /^-?\d+$/.test(v) ? Number(v) : v;
  if (typeof n !== "number" || !Number.isSafeInteger(n)) {
    throw new DataAccessError(operation, "shape");
  }
  return n;
}

export function boolField(operation: string, row: Row, key: string): boolean {
  const v = row[key];
  if (typeof v !== "boolean") throw new DataAccessError(operation, "shape");
  return v;
}

export function optionalDateField(
  operation: string,
  row: Row,
  key: string,
): CalendarDate | null {
  const v = row[key];
  if (v === null || v === undefined) return null;
  const d = typeof v === "string" ? tryParseCalendarDate(v) : null;
  if (d === null) throw new DataAccessError(operation, "shape");
  return d;
}

export function enumField<const T extends string>(
  operation: string,
  row: Row,
  key: string,
  allowed: readonly T[],
): T {
  const v = row[key];
  if (typeof v !== "string" || !(allowed as readonly string[]).includes(v)) {
    throw new DataAccessError(operation, "shape");
  }
  return v as T;
}

/* ── Money ────────────────────────────────────────────────────────────────── */

/**
 * Money is `numeric(10,2)` with an explicit currency, never a float (SDD §3.1).
 * PostgREST would serialise `numeric` as a JSON number, so every money column
 * is selected with a `::text` cast and travels as a decimal string from the
 * database to the renderer. No arithmetic is done on it in this layer.
 */
export type Money = { readonly amount: string; readonly currency: string };

/**
 * A non-negative decimal string with at most two fraction digits, or `null`.
 * `integerDigits` defaults to 8, which is what fits `numeric(10,2)`; sums
 * (`numeric(12,2)` in `today_screen`) pass 10.
 */
export function parseDecimal(value: unknown, integerDigits = 8): string | null {
  if (typeof value !== "string") return null;
  const pattern = new RegExp(`^\\d{1,${integerDigits}}(?:\\.\\d{1,2})?$`);
  return pattern.test(value) ? value : null;
}

export function optionalDecimalField(
  operation: string,
  row: Row,
  key: string,
): string | null {
  const v = row[key];
  if (v === null || v === undefined) return null;
  const d = parseDecimal(v);
  if (d === null) throw new DataAccessError(operation, "shape");
  return d;
}

/** ISO-4217 code as stored in `char(3)` columns. */
export function currencyField(operation: string, row: Row, key: string): string {
  const v = row[key];
  if (typeof v !== "string" || !/^[A-Z]{3}$/.test(v)) {
    throw new DataAccessError(operation, "shape");
  }
  return v;
}

/** An embedded to-one relation, which PostgREST returns as an object. */
export function embeddedOne(operation: string, row: Row, key: string): Row {
  const v = row[key];
  if (Array.isArray(v)) {
    if (v.length !== 1) throw new DataAccessError(operation, "shape");
    return asRow(operation, v[0]);
  }
  return asRow(operation, v);
}

/** An embedded to-many relation. */
export function embeddedMany(
  operation: string,
  row: Row,
  key: string,
): readonly Row[] {
  const v = row[key];
  if (v === null || v === undefined) return [];
  return asRows(operation, v);
}
