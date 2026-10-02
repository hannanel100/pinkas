import { Fragment, type ReactNode } from "react";

import { isMetric, type Phrase as PhraseValue } from "@/lib/i18n";

/**
 * A machine-readable quantity — a clock time, a date, a day count, a sum, a
 * progress fraction (SDD §10.3). Never prose.
 *
 * Two jobs, both load-bearing:
 *
 * 1. **IBM Plex Mono**, so `18` and `₪2,400` read as data at a glance.
 * 2. **`dir="ltr"`, isolated**, so `17:00`, `4 / 8` and `₪2,400` never reorder
 *    inside the RTL sentence around them (§11, invariant 8). `<bdi>` isolates
 *    its content from the surrounding bidi run; `dir="ltr"` fixes its base
 *    direction.
 *
 * The value only. A unit beside it ("יום") is prose and stays in Assistant —
 * use `<Phrase>` for a quantity with a unit, which places each half correctly.
 * Format the value with the `format*` helpers in `@/lib/i18n`.
 *
 * Colour is inherited, never set here: a Metric inside a risk component takes
 * the risk colour from its parent, and everywhere else it is ink or graphite.
 *
 * @example <Metric>{formatClock(session.scheduledAt)}</Metric>
 * @example <Metric className="text-[15px] font-medium">{formatShekels(open)}</Metric>
 */
export function Metric({
  children,
  className,
}: {
  readonly children: string | number;
  /** Size and weight only. The family and direction are not negotiable. */
  readonly className?: string;
}) {
  return (
    <bdi dir="ltr" className={className ? `font-mono ${className}` : "font-mono"}>
      {children}
    </bdi>
  );
}

/**
 * Renders a `Phrase` from the string layer: prose segments as text, metric
 * segments through `<Metric>`. This is how "18 יום" gets a mono `18` and an
 * Assistant `יום` without the string layer emitting markup.
 *
 * @example <Phrase value={t.count.days(18)} />
 */
export function Phrase({
  value,
  metricClassName,
}: {
  readonly value: PhraseValue;
  /** Passed to each `<Metric>` — size and weight only. */
  readonly metricClassName?: string;
}): ReactNode {
  return value.map((segment, i) =>
    isMetric(segment) ? (
      <Metric key={i} className={metricClassName}>
        {segment.metric}
      </Metric>
    ) : (
      <Fragment key={i}>{segment}</Fragment>
    ),
  );
}
