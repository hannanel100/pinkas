import { calendarDateParts, type CalendarDate } from "@/lib/domain/hebrew-calendar";

/**
 * Machine-readable quantities, formatted. No Hebrew lives here — these are the
 * strings that go *inside* a `<Metric>` (SDD §10.3), and they are formatted
 * the way the wireframe sets them: `17:00`, `12.07`, `₪2,400`, `4 / 8`.
 *
 * Deterministic by construction: every function takes its value as an
 * argument and none reads the clock or the host locale.
 */

const TIME_ZONE = "Asia/Jerusalem"; // SDD §9.4 — converted at the edge, here.

const clockFormat = new Intl.DateTimeFormat("en-GB", {
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
  timeZone: TIME_ZONE,
});

/** `17:00` — 24-hour wall-clock time in Israel, whatever the server's zone. */
export function formatClock(instant: Date): string {
  return clockFormat.format(instant);
}

/** `12.07` — day and month, as the wireframe's timeline and slots set them. */
export function formatDayMonth(date: CalendarDate): string {
  const { month, day } = calendarDateParts(date);
  return `${String(day).padStart(2, "0")}.${String(month).padStart(2, "0")}`;
}

/** `10.09.2026` — when the year matters (the portal's expiry date). */
export function formatDate(date: CalendarDate): string {
  return `${formatDayMonth(date)}.${calendarDateParts(date).year}`;
}

const wholeShekels = new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 });
const withAgorot = new Intl.NumberFormat("en-US", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

/**
 * `₪2,400`. Symbol first and Latin grouping, as the sheet sets it; agorot only
 * when there are any. `he-IL` currency formatting is deliberately not used — it
 * puts the symbol after the number and embeds RLM marks, which then fight the
 * `dir="ltr"` that `<Metric>` sets.
 */
export function formatShekels(amount: number): string {
  const sign = amount < 0 ? "-" : "";
  const abs = Math.abs(amount);
  const digits = Number.isInteger(abs)
    ? wholeShekels.format(abs)
    : withAgorot.format(abs);
  return `${sign}₪${digits}`;
}

/** `4 / 8` — a progress fraction (§10.3). */
export function formatFraction(done: number, total: number): string {
  return `${done} / ${total}`;
}
