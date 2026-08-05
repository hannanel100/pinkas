/**
 * WhatsApp message templates — SDD §14.2.
 *
 * Rendering is pure and **cannot throw**: the output of this function goes into
 * a message to a bride, so a template typo must degrade to an empty string and
 * a report to the editor, never to a literal `{{typo}}` in someone's WhatsApp
 * thread and never to an exception on the Today screen.
 *
 * Variables are **parsed from the body**, not stored in a column beside it
 * (`message_template.body` is the only source — see `schema.sql`). A stored
 * variable list can disagree with the text it describes; a parsed one cannot.
 *
 * What this module does *not* do: claim delivery. `message_log.status` is
 * `composed`, never `sent` (invariant 9, ADR-0007) — a `wa.me` deep link cannot
 * confirm that send was pressed, so nothing here reports more than "rendered".
 */

/** The variables the Phase-1 system templates use (§14.2). */
export const TEMPLATE_VARIABLES = [
  "bride_name",
  "date",
  "time",
  "location",
  "instructor_name",
] as const;

export type TemplateVariable = (typeof TEMPLATE_VARIABLES)[number];

export type TemplateValues = Readonly<
  Partial<Record<TemplateVariable, string | null | undefined>>
>;

/**
 * `{{name}}`, tolerating inner whitespace. Deliberately narrow: only a
 * `{{ identifier }}` is treated as a variable, so a stray brace in prose is
 * left exactly as the instructor typed it rather than being guessed at.
 */
const VARIABLE_PATTERN = /\{\{\s*([A-Za-z0-9_]*)\s*\}\}/g;

const KNOWN: ReadonlySet<string> = new Set<string>(TEMPLATE_VARIABLES);

export function isTemplateVariable(name: string): name is TemplateVariable {
  return KNOWN.has(name);
}

/** One variable as it appears in a body. */
export type TemplateVariableUse = {
  readonly name: string;
  readonly known: boolean;
  readonly occurrences: number;
};

/**
 * Every `{{…}}` in the body, in order of first appearance. This is what the
 * template editor lists, and what tells it a variable is misspelled *before*
 * the message is composed.
 */
export function parseTemplateVariables(
  body: string,
): readonly TemplateVariableUse[] {
  const uses = new Map<string, { known: boolean; occurrences: number }>();
  if (typeof body !== "string") return [];

  for (const match of body.matchAll(VARIABLE_PATTERN)) {
    const name = match[1] ?? "";
    const existing = uses.get(name);
    if (existing) {
      existing.occurrences += 1;
    } else {
      uses.set(name, { known: isTemplateVariable(name), occurrences: 1 });
    }
  }

  return [...uses].map(([name, use]) => ({
    name,
    known: use.known,
    occurrences: use.occurrences,
  }));
}

export type RenderedTemplate = {
  /** The message body. Safe to put in a `wa.me` link. */
  readonly text: string;
  /** Names in the body that are not template variables — reported, not emitted. */
  readonly unknownVariables: readonly string[];
  /** Known variables with no value: rendered empty, and worth telling her about. */
  readonly emptyVariables: readonly TemplateVariable[];
};

/**
 * Substitutes values into a body. Never throws.
 *
 * * An unknown variable renders **empty** and is reported (§14.2).
 * * A known variable with a missing, null or empty value renders **empty** and
 *   is reported — an empty `{{location}}` is a message worth a second look, not
 *   an error.
 * * Substitution is single-pass: a value that itself contains `{{…}}` is
 *   inserted literally and never re-expanded.
 * * Values are inserted verbatim. Hebrew, punctuation and bidi control
 *   characters are the caller's text and are not normalised, escaped or
 *   reordered here; `wa.me` URL-encoding happens at the link, not in the body.
 */
export function renderTemplate(
  body: string,
  values: TemplateValues = {},
): RenderedTemplate {
  if (typeof body !== "string") {
    return { text: "", unknownVariables: [], emptyVariables: [] };
  }

  const unknownVariables: string[] = [];
  const emptyVariables: TemplateVariable[] = [];
  const source: Record<string, string | null | undefined> =
    values && typeof values === "object"
      ? (values as Record<string, string | null | undefined>)
      : {};

  const text = body.replace(VARIABLE_PATTERN, (_match, rawName: string) => {
    const name = rawName ?? "";
    if (!isTemplateVariable(name)) {
      if (!unknownVariables.includes(name)) unknownVariables.push(name);
      return "";
    }
    const value = source[name];
    if (value === undefined || value === null || value === "") {
      if (!emptyVariables.includes(name)) emptyVariables.push(name);
      return "";
    }
    return value;
  });

  return { text, unknownVariables, emptyVariables };
}
