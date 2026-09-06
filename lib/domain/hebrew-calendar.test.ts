/**
 * Fixture tables for `hebrew-calendar.ts` — SDD §9, §17.2.
 *
 * The engine is pure, so every case here is a row in a table: an input, an
 * expected output, and no setup. `today` never appears because nothing in this
 * module reads a clock.
 */

import { describe, expect, it } from "vitest";
import { greg } from "@hebcal/core";

import {
  addDays,
  calendarDate,
  calendarUnavailability,
  compareDates,
  dayNumber,
  dayOfWeek,
  diffDays,
  fromDayNumber,
  fromHebrewDate,
  isHebrewLeapYear,
  isShabbat,
  parseCalendarDate,
  toHebrewDate,
  tryParseCalendarDate,
  type CalendarDate,
  type CalendarUnavailability,
} from "./hebrew-calendar";

const d = (value: string): CalendarDate => parseCalendarDate(value);

describe("CalendarDate construction", () => {
  const valid: ReadonlyArray<[number, number, number, string]> = [
    [2026, 1, 1, "2026-01-01"],
    [2026, 12, 31, "2026-12-31"],
    [2024, 2, 29, "2024-02-29"],
    [2000, 2, 29, "2000-02-29"],
  ];

  it.each(valid)("calendarDate(%i, %i, %i) = %s", (y, m, day, expected) => {
    expect(calendarDate(y, m, day)).toBe(expected);
  });

  const invalid: ReadonlyArray<[string, number, number, number]> = [
    ["month 0", 2026, 0, 1],
    ["month 13", 2026, 13, 1],
    ["day 0", 2026, 1, 0],
    ["31 September", 2026, 9, 31],
    ["29 February in a common year", 2026, 2, 29],
    ["29 February in 1900", 1900, 2, 29],
  ];

  it.each(invalid)("rejects %s", (_label, y, m, day) => {
    expect(() => calendarDate(y, m, day)).toThrow(RangeError);
  });

  const unparsable = [
    "2026-2-01",
    "2026/02/01",
    "20260201",
    "2026-02-30",
    "",
    "today",
  ];

  it.each(unparsable)("does not parse %j", (value) => {
    expect(tryParseCalendarDate(value)).toBeNull();
    expect(() => parseCalendarDate(value)).toThrow(RangeError);
  });
});

describe("day arithmetic is in civil days (§9.4)", () => {
  it("round-trips every day across a four-year window", () => {
    const start = dayNumber(d("2024-01-01"));
    const end = dayNumber(d("2028-01-01"));
    for (let rd = start; rd <= end; rd++) {
      expect(dayNumber(fromDayNumber(rd))).toBe(rd);
    }
  });

  it("agrees with @hebcal/core's Rata Die for the same window", () => {
    const start = dayNumber(d("2024-01-01"));
    const end = dayNumber(d("2028-01-01"));
    for (let rd = start; rd <= end; rd++) {
      const date = fromDayNumber(rd);
      const { year, month, day } = {
        year: Number(date.slice(0, 4)),
        month: Number(date.slice(5, 7)),
        day: Number(date.slice(8, 10)),
      };
      expect(greg.greg2abs(new Date(year, month - 1, day))).toBe(rd);
    }
  });

  // Israel's DST transitions: the last Friday of March and the last Sunday of
  // October. Adding 86 400-second multiples across these is the bug §9.4 says
  // the type exists to make unrepresentable.
  const dstTransitions: ReadonlyArray<[string, string, string]> = [
    ["spring forward 2026", "2026-03-26", "2026-03-28"],
    ["fall back 2026", "2026-10-24", "2026-10-26"],
    ["spring forward 2027", "2027-03-25", "2027-03-27"],
    ["fall back 2027", "2027-10-23", "2027-10-25"],
  ];

  it.each(dstTransitions)("%s is exactly two days", (_label, from, to) => {
    expect(diffDays(d(to), d(from))).toBe(2);
    expect(addDays(d(from), 2)).toBe(d(to));
    expect(addDays(d(to), -2)).toBe(d(from));
  });

  it("crosses month, year and leap-day boundaries", () => {
    expect(addDays(d("2026-12-31"), 1)).toBe(d("2027-01-01"));
    expect(addDays(d("2027-01-01"), -1)).toBe(d("2026-12-31"));
    expect(addDays(d("2024-02-28"), 1)).toBe(d("2024-02-29"));
    expect(addDays(d("2026-02-28"), 1)).toBe(d("2026-03-01"));
    expect(diffDays(d("2027-01-01"), d("2026-01-01"))).toBe(365);
    expect(diffDays(d("2025-01-01"), d("2024-01-01"))).toBe(366);
  });

  it("orders dates lexically and numerically alike", () => {
    expect(compareDates(d("2026-06-01"), d("2026-06-02"))).toBeLessThan(0);
    expect(compareDates(d("2026-06-02"), d("2026-06-01"))).toBeGreaterThan(0);
    expect(compareDates(d("2026-06-01"), d("2026-06-01"))).toBe(0);
    const sorted = [d("2026-10-01"), d("2026-02-01"), d("2026-06-01")].sort(
      compareDates,
    );
    expect(sorted).toEqual(["2026-02-01", "2026-06-01", "2026-10-01"]);
  });

  const weekdays: ReadonlyArray<[string, number]> = [
    ["2026-06-01", 1],
    ["2026-06-05", 5],
    ["2026-06-06", 6],
    ["2026-06-07", 0],
  ];

  it.each(weekdays)("%s has day-of-week %i", (value, expected) => {
    expect(dayOfWeek(d(value))).toBe(expected);
  });
});

describe("Hebrew calendar conversion (§9.1, §9.3)", () => {
  const conversions: ReadonlyArray<[string, number, number, number]> = [
    // [civil date, Hebrew year, month (1 = Nisan), day]
    ["2026-07-23", 5786, 5, 9], // 9 Av 5786 — Tisha B'Av
    ["2026-09-12", 5787, 7, 1], // 1 Tishrei 5787 — Rosh Hashana
    ["2027-02-08", 5787, 12, 1], // 1 Adar I 5787 — leap year
    ["2027-03-10", 5787, 13, 1], // 1 Adar II 5787
    ["2027-03-21", 5787, 13, 12],
  ];

  it.each(conversions)(
    "%s ⇄ %i-%i-%i",
    (civil, year, month, day) => {
      const hebrew = toHebrewDate(d(civil));
      expect([hebrew.year, hebrew.month, hebrew.day]).toEqual([
        year,
        month,
        day,
      ]);
      expect(fromHebrewDate(year, month, day)).toBe(d(civil));
    },
  );

  // §17.2 asks for Hebrew leap years explicitly: 5787 has thirteen months, so
  // Adar I and Adar II are distinct and a year is 383-385 days long.
  it("distinguishes Adar I from Adar II in a leap year", () => {
    expect(isHebrewLeapYear(5787)).toBe(true);
    expect(isHebrewLeapYear(5786)).toBe(false);

    const adarI = fromHebrewDate(5787, 12, 1);
    const adarII = fromHebrewDate(5787, 13, 1);
    expect(diffDays(adarII, adarI)).toBe(30);
    expect(toHebrewDate(adarI).isLeapYear).toBe(true);
  });

  it("keeps a leap year's length in civil days", () => {
    const leapStart = fromHebrewDate(5787, 7, 1);
    const leapEnd = fromHebrewDate(5788, 7, 1);
    const commonStart = fromHebrewDate(5786, 7, 1);
    const commonEnd = fromHebrewDate(5787, 7, 1);
    expect(diffDays(leapEnd, leapStart)).toBeGreaterThanOrEqual(383);
    expect(diffDays(commonEnd, commonStart)).toBeLessThanOrEqual(355);
  });
});

describe("unavailable days (§7.3 step 2)", () => {
  const cases: ReadonlyArray<
    [string, string, CalendarUnavailability | null]
  > = [
    ["plain Monday", "2026-06-01", null],
    ["Friday is a teaching day at day granularity", "2026-06-05", null],
    ["Saturday", "2026-06-06", { kind: "shabbat" }],
    [
      "Shabbat with a special-Shabbat event still reads as Shabbat",
      "2026-07-25",
      { kind: "shabbat" },
    ],
    [
      "Tisha B'Av",
      "2026-07-23",
      { kind: "fastDay", holiday: "Tish'a B'Av", severity: "major" },
    ],
    ["Erev Tisha B'Av is available", "2026-07-22", null],
    [
      "Tzom Tammuz is a minor fast",
      "2026-07-02",
      { kind: "fastDay", holiday: "Tzom Tammuz", severity: "minor" },
    ],
    [
      "Rosh Hashana day 1",
      "2026-09-12",
      { kind: "yomTov", holiday: "Rosh Hashana 5787" },
    ],
    [
      "Rosh Hashana day 2 — multi-day Yom Tov",
      "2026-09-13",
      { kind: "yomTov", holiday: "Rosh Hashana II" },
    ],
    ["Erev Rosh Hashana is available", "2026-09-11", null],
    [
      "Tzom Gedaliah",
      "2026-09-14",
      { kind: "fastDay", holiday: "Tzom Gedaliah", severity: "minor" },
    ],
    [
      "chol hamoed Sukkot",
      "2026-09-27",
      { kind: "cholHamoed", holiday: "Sukkot II (CH''M)" },
    ],
    ["Pesach I", "2027-04-22", { kind: "yomTov", holiday: "Pesach I" }],
    // Yom Kippur Katan recurs monthly and hebcal flags it MINOR_FAST. Treating
    // it as a fast day would delete a teaching day twelve times a year.
    ["Yom Kippur Katan is available", "2026-08-12", null],
    ["Rosh Chodesh is available", "2026-08-13", null],
    ["Purim Katan is available", "2027-02-21", null],
  ];

  it.each(cases)("%s: %s", (_label, date, expected) => {
    expect(calendarUnavailability(d(date))).toEqual(expected);
  });

  it("honours the observance knobs (§7.3 'as configured')", () => {
    expect(
      calendarUnavailability(d("2026-09-27"), { cholHamoed: "available" }),
    ).toBeNull();
    expect(
      calendarUnavailability(d("2026-09-14"), { minorFasts: "available" }),
    ).toBeNull();
    // A major fast is not configurable, and Shabbat still wins on Saturday.
    expect(
      calendarUnavailability(d("2026-07-23"), { minorFasts: "available" }),
    ).toEqual({ kind: "fastDay", holiday: "Tish'a B'Av", severity: "major" });
    expect(
      calendarUnavailability(d("2027-04-24"), { cholHamoed: "available" }),
    ).toEqual({ kind: "shabbat" });
  });

  it("reports the most explanatory reason when a holiday falls on Shabbat", () => {
    expect(isShabbat(d("2026-09-12"))).toBe(true);
    expect(calendarUnavailability(d("2026-09-12"))).toEqual({
      kind: "yomTov",
      holiday: "Rosh Hashana 5787",
    });
  });
});
