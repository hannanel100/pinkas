import type { RiskAssessment, RiskLevel } from "@/lib/domain/risk";

/**
 * The one place a risk level becomes a colour (invariant 7, SDD §10.2).
 *
 * Three colours for three levels. `info` and `none` are deliberately neutral:
 * the token set has exactly three chromatic values, and a fourth meaning would
 * dilute the other three (note a2). Lower severity also steps up in luminance
 * (#5), so the order survives greyscale.
 *
 * Class names are written out in full so Tailwind's scanner can see them —
 * never build them from the level string.
 */
type Tone = {
  /** The 4px inline-start edge of a risk row. */
  readonly edge: string;
  /** Text colour (and weight) of the day count. */
  readonly text: string;
  /** Border + text of the countdown chip. */
  readonly chip: string;
};

const NEUTRAL: Tone = {
  edge: "border-s-wire",
  text: "text-ink",
  chip: "border-wire text-ink",
};

export const TONE: Readonly<Record<RiskLevel, Tone>> = {
  critical: {
    edge: "border-s-risk-1",
    text: "text-risk-1 font-medium",
    chip: "border-risk-1 text-risk-1",
  },
  high: {
    edge: "border-s-risk-2",
    text: "text-risk-2",
    chip: "border-risk-2 text-risk-2",
  },
  medium: {
    edge: "border-s-risk-3",
    text: "text-risk-3",
    chip: "border-risk-3 text-risk-3",
  },
  info: NEUTRAL,
  none: NEUTRAL,
};

/** A verdict that has a reason — every level except `none`. */
export type AtRisk = Exclude<RiskAssessment, { readonly level: "none" }>;

export function isAtRisk(assessment: RiskAssessment): assessment is AtRisk {
  return assessment.level !== "none";
}
