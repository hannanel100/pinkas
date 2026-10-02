/**
 * The translation layer (SDD §11). Import `t` for copy, the formatters for the
 * values that go inside a `<Metric>`, and the Phrase helpers if you are
 * building a primitive that renders one.
 *
 * Phase 1 ships one locale, so `t` is the Hebrew catalog itself — no runtime
 * lookup, no provider, nothing in the client bundle that a server component
 * did not already render.
 */

export { he as t, type Catalog } from "./he";
export {
  formatClock,
  formatDate,
  formatDayMonth,
  formatFraction,
  formatShekels,
} from "./format";
export { fill, isMetric, metric, toText, type MetricSegment, type Phrase, type Segment } from "./phrase";
export { countPhrase, countText, type CountForms } from "./plural";
