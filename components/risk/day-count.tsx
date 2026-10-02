import { Phrase } from "@/components/ui";
import { t } from "@/lib/i18n";

/**
 * Days to the effective deadline — "18 יום", "יומיים" — or, for a course with
 * no deadline set, a word saying so. Never blank: the day count is half of
 * what keeps risk from being colour-only (§18.2).
 *
 * Internal to `components/risk/`; colour comes from the caller.
 */
export function DayCount({ days }: { readonly days: number | null }) {
  return days === null ? (
    <>{t.risk.noDeadline}</>
  ) : (
    <Phrase value={t.count.days(days)} />
  );
}
