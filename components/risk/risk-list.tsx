import { SectionLabel } from "@/components/ui";
import type { RiskAssessment } from "@/lib/domain/risk";
import { t } from "@/lib/i18n";

import { RiskRow } from "./risk-row";
import { isAtRisk } from "./tone";

export type RiskListItem = {
  /** Stable key — the course id. */
  readonly id: string;
  readonly name: string;
  readonly assessment: RiskAssessment;
  readonly href?: string;
};

/**
 * The first block on Today (plate 01, note a1): risk before sessions, before
 * money. Rows render in the order given — `v_course_risk` already ranks them,
 * and re-sorting here would make the screen and the view disagree.
 *
 * Rows at level `none` are dropped. If none remain, the block is the §8.5
 * empty state and nothing else: one sentence confirming the system checked —
 * no illustration, no greeting, no empty container. The absence of alarm is a
 * result, so it is stated as one.
 */
export function RiskList({
  items,
  sessionsToday,
}: {
  readonly items: readonly RiskListItem[];
  /** Today's session count, for the empty-state sentence. */
  readonly sessionsToday: number;
}) {
  const rows = items.flatMap((item) =>
    isAtRisk(item.assessment) ? [{ ...item, assessment: item.assessment }] : [],
  );

  if (rows.length === 0) {
    return (
      <section aria-label={t.risk.sectionLabel}>
        <p className="text-sm font-semibold">{t.today.allClear(sessionsToday)}</p>
      </section>
    );
  }

  return (
    <section aria-labelledby="risk-heading">
      <SectionLabel id="risk-heading" label={t.risk.sectionLabel} count={rows.length} />
      <ul>
        {rows.map((row) => (
          <RiskRow
            key={row.id}
            name={row.name}
            assessment={row.assessment}
            href={row.href}
          />
        ))}
      </ul>
    </section>
  );
}
