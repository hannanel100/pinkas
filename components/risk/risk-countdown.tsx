import type { RiskAssessment } from "@/lib/domain/risk";
import { t } from "@/lib/i18n";

import { DayCount } from "./day-count";
import { TONE } from "./tone";

/**
 * The countdown pinned to the bride's name on her card (plate 02, note b1):
 * days, not a date — "a date requires arithmetic; days do not". Its colour is
 * her risk level, consistent with Today.
 *
 * Plate 02 shows the chip alone, but a coloured chip alone is exactly what
 * §18.2 forbids. So whenever the chip carries a risk colour the reason
 * sentence renders beneath it, and the type takes the whole assessment so the
 * two cannot be separated by a caller. At `none` there is no colour and no
 * reason, and the chip is a plain neutral countdown.
 */
export function RiskCountdown({
  assessment,
}: {
  readonly assessment: RiskAssessment;
}) {
  const tone = TONE[assessment.level];
  return (
    <div className="grid justify-items-end gap-0.5 text-end">
      <p className={`border px-2 py-[3px] text-[11px] ${tone.chip}`}>
        <span className="sr-only">{t.risk.daysToDeadline} </span>
        <DayCount days={assessment.daysToDeadline} />
      </p>
      {assessment.level === "none" ? null : (
        <p className="text-graphite text-[11.5px]">{t.risk.reason(assessment)}</p>
      )}
    </div>
  );
}
