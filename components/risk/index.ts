/**
 * The only components permitted to emit colour (invariant 7, SDD §10.2). Every
 * one takes a whole `RiskAssessment`, never a bare level, so colour cannot be
 * rendered without its reason sentence and day count (§18.2).
 */
export { RiskCountdown } from "./risk-countdown";
export { RiskList, type RiskListItem } from "./risk-list";
export { RiskRow, type RiskRowProps } from "./risk-row";
export { isAtRisk, type AtRisk } from "./tone";
