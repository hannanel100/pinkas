/**
 * Dates and the Hebrew calendar — SDD §9.
 *
 * This module owns two things:
 *
 * 1. `CalendarDate`, the civil-day date type every other engine works in.
 *    §9.4: "the scheduling engine works in `CalendarDate`, not epoch seconds,
 *    specifically to make this class of bug unrepresentable." Israel observes
 *    DST, so adding 86 400-second multiples across a transition is a real bug.
 *    A `CalendarDate` is a branded `YYYY-MM-DD` string and all arithmetic goes
 *    through Rata Die day numbers — integers, no clock, no timezone, no `Date`.
 *
 * 2. The Hebrew/Gregorian conversion and the unavailable-day calendar. §9.3:
 *    this is *the only module that reads the conversion*, so if the Phase-1
 *    simplification below has to change, it changes here and nowhere else.
 *
 * ── Phase-1 simplifications, stated openly (§9.3, §9.2) ────────────────────
 *
 * * **Hebrew dates are civil dates with no sunset rollover.** כ״ב באב maps to
 *   one Gregorian date, not to "after sunset on the 21st". Safe only because
 *   the deadline is cushioned by a two-week buffer (§7.2); never extend this
 *   assumption to anything computing halachic times.
 *
 * * **Unavailability is evaluated at day granularity.** §9.2 describes Shabbat
 *   as Friday sunset → Saturday nightfall. A scheduling slot in Phase 1 carries
 *   a date and no time of day, so "Friday evening" is not representable in the
 *   output: Saturday is unavailable, Friday is available. When sessions carry a
 *   time of day, the Friday cutoff is candle-lighting for her city and it is
 *   computed here — `@hebcal/core`'s `Zmanim` is pure, so that change stays
 *   inside this module too.
 *
 * Invariant 4: no I/O, no clock. `today` is injected by the caller.
 */

import { HDate, flags, getHolidaysOnDate } from "@hebcal/core";

/* ── CalendarDate ─────────────────────────────────────────────────────────── */

declare const calendarDateBrand: unique symbol;

/**
 * A civil date in `YYYY-MM-DD` form. Branded so an arbitrary string cannot be
 * passed where a date is meant, and so day arithmetic cannot be done by
 * accident on a timestamp.
 */
export type CalendarDate = string & { readonly [calendarDateBrand]: true };

const DATE_PATTERN = /^(-?\d{4,})-(\d{2})-(\d{2})$/;

function isGregorianLeapYear(year: number): boolean {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}

function daysInGregorianMonth(year: number, month: number): number {
  switch (month) {
    case 2:
      return isGregorianLeapYear(year) ? 29 : 28;
    case 4:
    case 6:
    case 9:
    case 11:
      return 30;
    default:
      return 31;
  }
}

function pad(value: number, width: number): string {
  const sign = value < 0 ? "-" : "";
  return sign + String(Math.abs(value)).padStart(width, "0");
}

/**
 * Rata Die day number for a Gregorian date (RD 1 = 0001-01-01). The formula is
 * Reingold & Dershowitz's `fixed-from-gregorian`; it is integer arithmetic only.
 */
function fixedFromGregorian(year: number, month: number, day: number): number {
  const priorYears = year - 1;
  const monthCorrection = month <= 2 ? 0 : isGregorianLeapYear(year) ? -1 : -2;
  return (
    365 * priorYears +
    Math.floor(priorYears / 4) -
    Math.floor(priorYears / 100) +
    Math.floor(priorYears / 400) +
    Math.floor((367 * month - 362) / 12) +
    monthCorrection +
    day
  );
}

function gregorianYearFromFixed(dayNumber: number): number {
  const d0 = dayNumber - 1;
  const n400 = Math.floor(d0 / 146097);
  const d1 = d0 - 146097 * n400;
  const n100 = Math.floor(d1 / 36524);
  const d2 = d1 - 36524 * n100;
  const n4 = Math.floor(d2 / 1461);
  const d3 = d2 - 1461 * n4;
  const n1 = Math.floor(d3 / 365);
  const year = 400 * n400 + 100 * n100 + 4 * n4 + n1;
  return n100 === 4 || n1 === 4 ? year : year + 1;
}

/** Calendar parts of a civil date. `month` is 1-12. */
export type CalendarDateParts = {
  readonly year: number;
  readonly month: number;
  readonly day: number;
};

/** Constructs a `CalendarDate`. Throws `RangeError` on an impossible date. */
export function calendarDate(
  year: number,
  month: number,
  day: number,
): CalendarDate {
  if (
    !Number.isInteger(year) ||
    !Number.isInteger(month) ||
    !Number.isInteger(day) ||
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > daysInGregorianMonth(year, month)
  ) {
    throw new RangeError(
      `Not a calendar date: ${year}-${month}-${day}. CalendarDate is a civil date (SDD §9.4).`,
    );
  }
  return `${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}` as CalendarDate;
}

/** Parses `YYYY-MM-DD`. Returns `null` rather than throwing. */
export function tryParseCalendarDate(value: string): CalendarDate | null {
  const match = DATE_PATTERN.exec(value);
  if (!match) return null;
  const [, y, m, d] = match;
  if (y === undefined || m === undefined || d === undefined) return null;
  try {
    return calendarDate(Number(y), Number(m), Number(d));
  } catch {
    return null;
  }
}

/** Parses `YYYY-MM-DD`. Throws `RangeError` on anything else. */
export function parseCalendarDate(value: string): CalendarDate {
  const parsed = tryParseCalendarDate(value);
  if (parsed === null) {
    throw new RangeError(`Not a YYYY-MM-DD calendar date: ${JSON.stringify(value)}`);
  }
  return parsed;
}

/** Splits a `CalendarDate` into its parts. */
export function calendarDateParts(date: CalendarDate): CalendarDateParts {
  const match = DATE_PATTERN.exec(date);
  /* c8 ignore next 3 -- unreachable: the brand guarantees the shape. */
  if (!match) {
    throw new RangeError(`Corrupt CalendarDate: ${JSON.stringify(date)}`);
  }
  return {
    year: Number(match[1]),
    month: Number(match[2]),
    day: Number(match[3]),
  };
}

/**
 * Rata Die day number. This is the only representation day arithmetic uses —
 * an integer count of civil days, immune to DST (§9.4).
 */
export function dayNumber(date: CalendarDate): number {
  const { year, month, day } = calendarDateParts(date);
  return fixedFromGregorian(year, month, day);
}

/** Inverse of {@link dayNumber}. */
export function fromDayNumber(rataDie: number): CalendarDate {
  const year = gregorianYearFromFixed(rataDie);
  const priorDays = rataDie - fixedFromGregorian(year, 1, 1);
  const correction =
    rataDie < fixedFromGregorian(year, 3, 1)
      ? 0
      : isGregorianLeapYear(year)
        ? 1
        : 2;
  const month = Math.floor((12 * (priorDays + correction) + 373) / 367);
  const day = rataDie - fixedFromGregorian(year, month, 1) + 1;
  return calendarDate(year, month, day);
}

/** Adds whole civil days. Negative values subtract. */
export function addDays(date: CalendarDate, days: number): CalendarDate {
  return fromDayNumber(dayNumber(date) + days);
}

/** `a - b`, in whole civil days. Positive when `a` is later. */
export function diffDays(a: CalendarDate, b: CalendarDate): number {
  return dayNumber(a) - dayNumber(b);
}

/** Sort comparator: negative when `a` is earlier. */
export function compareDates(a: CalendarDate, b: CalendarDate): number {
  return dayNumber(a) - dayNumber(b);
}

export function isBefore(a: CalendarDate, b: CalendarDate): boolean {
  return compareDates(a, b) < 0;
}

export function isAfter(a: CalendarDate, b: CalendarDate): boolean {
  return compareDates(a, b) > 0;
}

export function isSameDay(a: CalendarDate, b: CalendarDate): boolean {
  return a === b;
}

export function minDate(a: CalendarDate, b: CalendarDate): CalendarDate {
  return isBefore(a, b) ? a : b;
}

export function maxDate(a: CalendarDate, b: CalendarDate): CalendarDate {
  return isAfter(a, b) ? a : b;
}

/** Day of week, 0 = Sunday … 6 = Saturday. */
export function dayOfWeek(date: CalendarDate): number {
  const rd = dayNumber(date);
  return ((rd % 7) + 7) % 7;
}

const SATURDAY = 6;

/** True on Saturday. See the day-granularity note in the module header. */
export function isShabbat(date: CalendarDate): boolean {
  return dayOfWeek(date) === SATURDAY;
}

/* ── Hebrew calendar ──────────────────────────────────────────────────────── */

/**
 * A Hebrew date. `month` is 1 = Nisan … 7 = Tishrei, as `@hebcal/core` numbers
 * them; `monthName` is the stable English transliteration, never a rendered
 * Hebrew string — Hebrew belongs to the translation layer (§8.3, invariant 8).
 */
export type HebrewDate = {
  readonly year: number;
  readonly month: number;
  readonly day: number;
  readonly monthName: string;
  readonly isLeapYear: boolean;
};

/**
 * Civil date → Hebrew date. Phase-1 simplification (§9.3): the daytime portion
 * only, with no sunset rollover.
 */
export function toHebrewDate(date: CalendarDate): HebrewDate {
  const hd = new HDate(dayNumber(date));
  return {
    year: hd.getFullYear(),
    month: hd.getMonth(),
    day: hd.getDate(),
    monthName: hd.getMonthName(),
    isLeapYear: hd.isLeapYear(),
  };
}

/**
 * Hebrew date → civil date. The counterpart of `bride.wedding_date_source =
 * 'hebrew'` (§9.1): the instructor types כ״ב באב, this maps it to the one
 * Gregorian date stored in `wedding_date`.
 */
export function fromHebrewDate(
  year: number,
  month: number,
  day: number,
): CalendarDate {
  return fromDayNumber(HDate.hebrew2abs(year, month, day));
}

/** True when the Hebrew year has 13 months (Adar I and Adar II). */
export function isHebrewLeapYear(year: number): boolean {
  return HDate.isLeapYear(year);
}

/* ── The unavailable-day calendar (§7.3 step 2) ───────────────────────────── */

/**
 * Why a day is unavailable, as a reason code plus operands — never a rendered
 * sentence. `holiday` is `@hebcal/core`'s untranslated description, which that
 * library documents as stable across releases; the Hebrew sentence is composed
 * in the translation layer (§7.6, §8.3).
 */
export type CalendarUnavailability =
  | { readonly kind: "shabbat" }
  | { readonly kind: "yomTov"; readonly holiday: string }
  | { readonly kind: "cholHamoed"; readonly holiday: string }
  | {
      readonly kind: "fastDay";
      readonly holiday: string;
      readonly severity: "major" | "minor";
    };

/**
 * §7.3 says "Yom Tov and chol hamoed **as configured**, fast days". Nothing in
 * the Phase-1 schema stores that configuration, so the defaults below are the
 * design's answer and the knobs exist for when it does.
 */
export type Observance = {
  /** Israeli holiday schedule (one day of Yom Tov). Default `true`. */
  readonly israel?: boolean;
  /** Chol hamoed. Default `"unavailable"`, per §7.3. */
  readonly cholHamoed?: "unavailable" | "available";
  /** Minor fasts (Tzom Gedaliah, Ta'anit Esther…). Default `"unavailable"`. */
  readonly minorFasts?: "unavailable" | "available";
};

export const DEFAULT_OBSERVANCE: Required<Observance> = {
  israel: true,
  cholHamoed: "unavailable",
  minorFasts: "unavailable",
};

function resolveObservance(observance?: Observance): Required<Observance> {
  return { ...DEFAULT_OBSERVANCE, ...observance };
}

/**
 * The calendar-derived reason this day cannot hold a session, or `null`.
 *
 * Order matters: the most explanatory reason wins, because the bride-facing
 * line is "skipped · Tisha B'Av", not "skipped · unavailable" (§7.6). A Yom Tov
 * that falls on Saturday reports the Yom Tov; a plain Saturday reports Shabbat.
 *
 * Two classes of event are filtered out before anything else is decided:
 *
 * * **Erev anything.** An erev event carries the following day's flags — Erev
 *   Tish'a B'Av is itself flagged `MAJOR_FAST` — so leaving it in would block
 *   the day before every holiday.
 * * **Yom Kippur Katan**, which `@hebcal/core` also flags `MINOR_FAST`. It
 *   recurs monthly and is a custom kept by few; treating it as a fast day would
 *   silently delete a teaching day twelve times a year.
 */
export function calendarUnavailability(
  date: CalendarDate,
  observance?: Observance,
): CalendarUnavailability | null {
  const settings = resolveObservance(observance);
  const ignored = flags.EREV | flags.YOM_KIPPUR_KATAN;
  const events = (
    getHolidaysOnDate(dayNumber(date), settings.israel) ?? []
  ).filter((event) => (event.getFlags() & ignored) === 0);

  for (const event of events) {
    if ((event.getFlags() & flags.CHAG) !== 0) {
      return { kind: "yomTov", holiday: event.getDesc() };
    }
  }
  for (const event of events) {
    if ((event.getFlags() & flags.MAJOR_FAST) !== 0) {
      return { kind: "fastDay", holiday: event.getDesc(), severity: "major" };
    }
  }
  if (settings.cholHamoed === "unavailable") {
    for (const event of events) {
      if ((event.getFlags() & flags.CHOL_HAMOED) !== 0) {
        return { kind: "cholHamoed", holiday: event.getDesc() };
      }
    }
  }
  if (settings.minorFasts === "unavailable") {
    for (const event of events) {
      if ((event.getFlags() & flags.MINOR_FAST) !== 0) {
        return { kind: "fastDay", holiday: event.getDesc(), severity: "minor" };
      }
    }
  }
  if (isShabbat(date)) return { kind: "shabbat" };
  return null;
}
