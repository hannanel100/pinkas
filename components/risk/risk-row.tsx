import Link from "next/link";

import { t } from "@/lib/i18n";

import { DayCount } from "./day-count";
import { TONE, type AtRisk } from "./tone";

export type RiskRowProps = {
  /** The bride's display name. Prose. */
  readonly name: string;
  /** The verdict — level, reason code, operands and day count, from `v_course_risk`. */
  readonly assessment: AtRisk;
  /** Where tapping the row goes — normally her card, `/brides/[id]`. */
  readonly href?: string;
};

/**
 * One at-risk bride on Today (plate 01, `.risk`). Renders as an `<li>`; use it
 * inside `<RiskList>` or another `<ul>`.
 *
 * Colour is never alone (§18.2): the level's colour on the inline-start edge
 * and the day count is always accompanied by the reason sentence composed from
 * the code and its operands (§8.3, note a3) and by the day count itself. The
 * type makes that structural — the component takes the whole assessment, so
 * there is no way to hand it a colour without a reason.
 */
export function RiskRow({ name, assessment, href }: RiskRowProps) {
  const tone = TONE[assessment.level];
  return (
    <li
      className={`border-wire relative mb-[7px] flex items-center justify-between gap-2 border border-s-4 px-[11px] py-[9px] ${tone.edge}`}
    >
      <div className="min-w-0">
        <p className="text-sm font-semibold">
          {href ? (
            // Stretched link: the whole row is the tap target on a 375px screen.
            <Link href={href} className="after:absolute after:inset-0">
              {name}
            </Link>
          ) : (
            name
          )}
        </p>
        <p className="text-graphite mt-px text-[11.5px]">
          {t.risk.reason(assessment)}
        </p>
      </div>
      <p className={`shrink-0 text-[11px] ${tone.text}`}>
        <span className="sr-only">{t.risk.daysToDeadline} </span>
        <DayCount days={assessment.daysToDeadline} />
      </p>
    </li>
  );
}
