/**
 * Fixture tables for `templates.ts` — SDD §14.2, §17.2.
 *
 * §17.2 asks for three cases: unknown variable, empty value, RTL punctuation.
 * The through-line is that this output goes into a message to a bride, so the
 * only acceptable failure mode is a silent empty string plus a report to the
 * editor — never an exception, never a literal `{{typo}}`.
 */

import { describe, expect, it } from "vitest";

import {
  TEMPLATE_VARIABLES,
  isTemplateVariable,
  parseTemplateVariables,
  renderTemplate,
  type TemplateValues,
} from "./templates";

const REMINDER =
  "היי {{bride_name}}, נזכיר שהמפגש הבא שלנו ב־{{date}} בשעה {{time}} ב{{location}}. נתראה! {{instructor_name}}";

const VALUES: TemplateValues = {
  bride_name: "נועה",
  date: "12.6",
  time: "19:00",
  location: "הרצל 14, פתח תקווה",
  instructor_name: "מיכל",
};

describe("variables are parsed from the body, never stored (§14.2)", () => {
  it("lists the five system variables", () => {
    expect([...TEMPLATE_VARIABLES]).toEqual([
      "bride_name",
      "date",
      "time",
      "location",
      "instructor_name",
    ]);
    expect(isTemplateVariable("bride_name")).toBe(true);
    expect(isTemplateVariable("brides_name")).toBe(false);
  });

  it("reports each variable once, with its occurrence count", () => {
    expect(
      parseTemplateVariables("{{bride_name}} {{date}} {{bride_name}}"),
    ).toEqual([
      { name: "bride_name", known: true, occurrences: 2 },
      { name: "date", known: true, occurrences: 1 },
    ]);
  });

  it("marks a misspelled variable as unknown before it is ever composed", () => {
    expect(parseTemplateVariables("{{bride_nmae}}")).toEqual([
      { name: "bride_nmae", known: false, occurrences: 1 },
    ]);
  });

  it("tolerates whitespace inside the braces", () => {
    expect(parseTemplateVariables("{{ bride_name }}")).toEqual([
      { name: "bride_name", known: true, occurrences: 1 },
    ]);
  });

  it("finds nothing in a body with no variables", () => {
    expect(parseTemplateVariables("שלום")).toEqual([]);
    expect(parseTemplateVariables("")).toEqual([]);
  });
});

type Row = {
  readonly name: string;
  readonly body: string;
  readonly values: TemplateValues;
  readonly text: string;
  readonly unknownVariables?: readonly string[];
  readonly emptyVariables?: readonly string[];
};

const rows: readonly Row[] = [
  {
    name: "the system reminder, fully populated",
    body: REMINDER,
    values: VALUES,
    text: "היי נועה, נזכיר שהמפגש הבא שלנו ב־12.6 בשעה 19:00 בהרצל 14, פתח תקווה. נתראה! מיכל",
  },
  {
    name: "an unknown variable renders empty and is reported",
    body: "היי {{bride_nmae}}, נתראה",
    values: VALUES,
    text: "היי , נתראה",
    unknownVariables: ["bride_nmae"],
  },
  {
    name: "a missing value renders empty and is reported",
    body: "המפגש ב{{location}}",
    values: { bride_name: "נועה" },
    text: "המפגש ב",
    emptyVariables: ["location"],
  },
  {
    name: "an empty-string value counts as empty",
    body: "המפגש ב{{location}}",
    values: { location: "" },
    text: "המפגש ב",
    emptyVariables: ["location"],
  },
  {
    name: "a null value counts as empty",
    body: "המפגש ב{{location}}",
    values: { location: null },
    text: "המפגש ב",
    emptyVariables: ["location"],
  },
  {
    name: "whitespace inside the braces still substitutes",
    body: "היי {{ bride_name }}",
    values: VALUES,
    text: "היי נועה",
  },
  {
    name: "the same variable twice",
    body: "{{bride_name}} — {{bride_name}}",
    values: VALUES,
    text: "נועה — נועה",
  },
  {
    name: "several unknowns are each reported once",
    body: "{{a}} {{b}} {{a}}",
    values: VALUES,
    text: "  ",
    unknownVariables: ["a", "b"],
  },
  {
    name: "an unclosed brace is left exactly as she typed it",
    body: "היי {{bride_name, נתראה",
    values: VALUES,
    text: "היי {{bride_name, נתראה",
  },
  {
    name: "a value containing braces is inserted, never re-expanded",
    body: "היי {{bride_name}}",
    values: { bride_name: "{{instructor_name}}" },
    text: "היי {{instructor_name}}",
  },
  {
    name: "an empty body renders empty",
    body: "",
    values: VALUES,
    text: "",
  },
  {
    name: "no values at all: everything known renders empty and is reported",
    body: "{{bride_name}}|{{date}}",
    values: {},
    text: "|",
    emptyVariables: ["bride_name", "date"],
  },
  /* ── RTL punctuation (§17.2) ───────────────────────────────────────────── */
  {
    name: "RTL punctuation and the geresh/maqaf survive untouched",
    body: "היי {{bride_name}}! המפגש ב־{{date}}, בשעה {{time}} — נתראה?",
    values: VALUES,
    text: "היי נועה! המפגש ב־12.6, בשעה 19:00 — נתראה?",
  },
  {
    name: "a value carrying its own RTL punctuation is inserted verbatim",
    body: "כתובת: {{location}}",
    values: { location: "רח׳ הרצל 14, ת״א (קומה 2)" },
    text: "כתובת: רח׳ הרצל 14, ת״א (קומה 2)",
  },
  {
    name: "bidi control characters are not stripped or normalised",
    body: "{{bride_name}}‏ — {{time}}",
    values: { bride_name: "נועה‎", time: "19:00" },
    text: "נועה‎‏ — 19:00",
  },
  {
    name: "a mixed Hebrew/Latin value keeps its exact code points",
    body: "{{location}}",
    values: { location: "Zoom — קישור בהמשך" },
    text: "Zoom — קישור בהמשך",
  },
];

describe("renderTemplate", () => {
  it.each(rows)("$name", (row) => {
    const rendered = renderTemplate(row.body, row.values);
    expect(rendered.text).toBe(row.text);
    expect(rendered.unknownVariables).toEqual(row.unknownVariables ?? []);
    expect(rendered.emptyVariables).toEqual(row.emptyVariables ?? []);
  });

  it("never emits a literal {{…}} for a variable it did not resolve", () => {
    for (const row of rows) {
      const rendered = renderTemplate(row.body, row.values);
      for (const use of parseTemplateVariables(row.body)) {
        expect(rendered.text).not.toContain(`{{${use.name}}}`);
      }
    }
  });

  it("never throws, whatever it is handed", () => {
    const hostile: unknown[] = [
      undefined,
      null,
      42,
      {},
      [],
      "{{".repeat(500) + "}}".repeat(500),
    ];
    for (const body of hostile) {
      expect(() =>
        renderTemplate(body as string, VALUES),
      ).not.toThrow();
    }
    expect(() =>
      renderTemplate(REMINDER, undefined as unknown as TemplateValues),
    ).not.toThrow();
    expect(() =>
      renderTemplate(REMINDER, null as unknown as TemplateValues),
    ).not.toThrow();
  });

  it("is pure: the same body and values render the same text", () => {
    expect(renderTemplate(REMINDER, VALUES)).toEqual(
      renderTemplate(REMINDER, VALUES),
    );
  });
});
