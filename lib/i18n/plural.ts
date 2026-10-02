import { fill, metric, toText, type Phrase } from "./phrase";

/**
 * Hebrew counted nouns. Concatenating `${n} ימים` is wrong twice over: Hebrew
 * says "יום אחד" (noun first, no numeral) for one, has a dual for some nouns
 * ("יומיים", not "2 ימים"), and with numbers above ten some nouns — יום, שנה —
 * conventionally return to the singular ("18 יום", "9 ימים"). The wireframe
 * uses exactly those forms.
 *
 * CLDR's `Intl.PluralRules("he")` does not model the above-ten singular, so the
 * selection is written out here rather than delegated.
 *
 * Templates use `{n}` for the numeral.
 */
export type CountForms = {
  /** n = 1. Usually carries no numeral: "יום אחד", "מפגש אחד". */
  readonly one: string;
  /** n = 2, for nouns with a dual ("יומיים"). Omit to use `few`. */
  readonly two?: string;
  /** n = 0, and 3–10 (and 2 without a dual): "{n} ימים". */
  readonly few: string;
  /** n > 10, for nouns that take the singular there ("{n} יום"). Omit to use `few`. */
  readonly many?: string;
};

function select(n: number, forms: CountForms): string {
  if (!Number.isInteger(n) || n < 0) {
    throw new RangeError(`A count is a non-negative integer, got ${n}`);
  }
  if (n === 1) return forms.one;
  if (n === 2 && forms.two !== undefined) return forms.two;
  if (n > 10 && forms.many !== undefined) return forms.many;
  return forms.few;
}

/**
 * The count as a {@link Phrase}: the numeral is a metric segment (mono, LTR)
 * and the noun is prose. For a quantity that stands alone as data — the
 * countdown chip, the risk row's day count.
 */
export function countPhrase(n: number, forms: CountForms): Phrase {
  return fill(select(n, forms), { n: metric(n) });
}

/** The count as prose, for use inside a sentence. */
export function countText(n: number, forms: CountForms): string {
  return toText(fill(select(n, forms), { n: String(n) }));
}
