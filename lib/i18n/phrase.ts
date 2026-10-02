/**
 * A `Phrase` is copy that contains a machine-readable quantity — "18 יום",
 * where `18` must render in IBM Plex Mono with `dir="ltr"` and `יום` is prose
 * that stays in Assistant (SDD §10.3, invariant 8).
 *
 * A plain string cannot carry that distinction, and a pre-rendered React node
 * would put markup in the string layer. So the layer returns segments, and
 * `<Phrase>` in `components/ui/` is the one place that turns a `metric`
 * segment into a `<Metric>`.
 *
 * Use a Phrase only where the quantity stands on its own as data (a countdown,
 * a sum). A number *inside a sentence* — "4 מפגשים נותרו" — is prose, and the
 * sentence is a plain string. That is how the wireframe sets them, and it is
 * what "prose is never a Metric" means.
 */

export type MetricSegment = { readonly metric: string };
export type Segment = string | MetricSegment;
export type Phrase = readonly Segment[];

export function metric(value: string | number): MetricSegment {
  return { metric: String(value) };
}

export function isMetric(segment: Segment): segment is MetricSegment {
  return typeof segment !== "string";
}

/**
 * Fills `{name}` placeholders. A placeholder whose value is a
 * {@link MetricSegment} becomes a metric segment; a string value is spliced in
 * as prose. Unknown placeholders throw — a missing operand is a bug in the
 * catalog, and rendering "{n}" to her would be worse than failing the test.
 */
export function fill(
  template: string,
  values: Readonly<Record<string, Segment>>,
): Phrase {
  const out: Segment[] = [];
  let text = "";
  let last = 0;
  for (const match of template.matchAll(/\{(\w+)\}/g)) {
    const [whole, name] = match;
    const value = name === undefined ? undefined : values[name];
    if (value === undefined) {
      throw new Error(`Missing operand {${name}} in ${JSON.stringify(template)}`);
    }
    text += template.slice(last, match.index);
    last = match.index + whole.length;
    if (typeof value === "string") {
      text += value;
    } else {
      if (text) out.push(text);
      text = "";
      out.push(value);
    }
  }
  text += template.slice(last);
  if (text) out.push(text);
  return out;
}

/** Flattens a Phrase to a plain string — for `aria-label`, `<title>`, tests. */
export function toText(phrase: Phrase): string {
  return phrase.map((s) => (typeof s === "string" ? s : s.metric)).join("");
}
