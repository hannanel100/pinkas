/**
 * The one place `lib/data/` turns an instant into an Israeli civil date
 * (SDD §9.4). The domain engines never read the clock (invariant 4); this layer
 * reads it once per request and injects `today`.
 *
 * `Intl` does the timezone work — no offset arithmetic here, so DST is the
 * platform's problem, not ours.
 */

import { parseCalendarDate, type CalendarDate } from "@/lib/domain/hebrew-calendar";

export const TIMEZONE = "Asia/Jerusalem";

const FORMAT = new Intl.DateTimeFormat("en-CA", {
  timeZone: TIMEZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

/** The Israeli civil date of an instant. */
export function jerusalemDate(at: Date): CalendarDate {
  const parts = FORMAT.formatToParts(at);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  return parseCalendarDate(`${get("year")}-${get("month")}-${get("day")}`);
}

/** The Israeli civil date of an ISO 8601 instant string. */
export function jerusalemDateOf(instant: string): CalendarDate {
  const at = new Date(instant);
  if (Number.isNaN(at.getTime())) {
    throw new RangeError("Not an ISO 8601 instant.");
  }
  return jerusalemDate(at);
}

/** Today, in Israel. The only clock read in `lib/data/`. */
export function jerusalemToday(): CalendarDate {
  return jerusalemDate(new Date());
}

const TIME = /^([01]\d|2[0-3]):([0-5]\d)$/;

/** `HH:MM`, 24-hour, as a session's local time of day. */
export type LocalTime = `${number}:${number}`;

export function parseLocalTime(value: unknown): LocalTime | null {
  return typeof value === "string" && TIME.test(value) ? (value as LocalTime) : null;
}

/**
 * A civil date and a local time, as a `timestamptz` input literal Postgres
 * resolves in Asia/Jerusalem — so the conversion, DST included, happens in the
 * database rather than in arithmetic here.
 */
export function jerusalemTimestampLiteral(date: CalendarDate, time: LocalTime): string {
  return `${date} ${time}:00 ${TIMEZONE}`;
}
