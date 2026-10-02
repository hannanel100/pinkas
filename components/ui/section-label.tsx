import { Metric } from "./metric";

/**
 * The small heading above a block, with an optional count at the inline end —
 * "דורש תשומת לב · 3", "מפגשים היום · 2" on plate 01.
 *
 * Renders an `<h2>` so each block is a navigable landmark heading (§18.2). The
 * label is prose (Assistant); the count is a quantity (`<Metric>`).
 *
 * @example <SectionLabel id="risk-heading" label={t.risk.sectionLabel} count={rows.length} />
 */
export function SectionLabel({
  id,
  label,
  count,
}: {
  /** For `aria-labelledby` on the enclosing `<section>`. */
  readonly id?: string;
  readonly label: string;
  readonly count?: number;
}) {
  return (
    <h2
      id={id}
      className="text-graphite mb-2 flex items-center justify-between text-[11px] font-normal tracking-[0.1em]"
    >
      <span>{label}</span>
      {count === undefined ? null : <Metric>{count}</Metric>}
    </h2>
  );
}
