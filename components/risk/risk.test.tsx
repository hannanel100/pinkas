import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { RiskAssessment } from "@/lib/domain/risk";
import { t, toText } from "@/lib/i18n";

import { RiskCountdown, RiskList, RiskRow, type AtRisk } from "./index";

/**
 * The component half of invariants 7 and 8. Expected copy is read from `t`
 * rather than restated: the string layer's own tests pin the Hebrew to the
 * wireframe, and these pin the components to the string layer.
 */

const render = (node: React.ReactNode) => renderToStaticMarkup(node);

/** Markup → visible text, for asserting what a reader actually gets. */
const text = (html: string) =>
  html
    .replace(/<span class="sr-only">[^<]*<\/span>/g, "")
    .replace(/<[^>]+>/g, "");

const critical: AtRisk = {
  level: "critical",
  reasonCode: "wont_finish_in_time",
  daysToDeadline: 18,
  operands: { sessionsRemaining: 4, wholeWeeksToDeadline: 2 },
};
const high: AtRisk = {
  level: "high",
  reasonCode: "cancelled_not_rescheduled",
  daysToDeadline: 9,
  operands: { staleCancellations: 1, thresholdDays: 7 },
};
const medium: AtRisk = {
  level: "medium",
  reasonCode: "no_recent_session",
  daysToDeadline: 24,
  operands: { daysSinceLastSession: 22, thresholdDays: 21 },
};
const info: AtRisk = {
  level: "info",
  reasonCode: "wedding_approaching",
  daysToDeadline: null,
  operands: { daysToWedding: 12, thresholdDays: 30 },
};
const none: RiskAssessment = { level: "none", reasonCode: null, daysToDeadline: 40 };

const RISK_CLASS = /\b(?:text|border|border-s)-risk-[123]\b/;

describe("colour is never alone (§18.2)", () => {
  const cases: Array<[string, AtRisk]> = [
    ["critical", critical],
    ["high", high],
    ["medium", medium],
    ["info", info],
  ];

  it.each(cases)("RiskRow at %s renders its reason and its day count", (_, a) => {
    const html = render(<RiskRow name="N" assessment={a} />);
    const visible = text(html);
    expect(visible).toContain(t.risk.reason(a));
    expect(visible).toContain(
      a.daysToDeadline === null ? t.risk.noDeadline : toText(t.count.days(a.daysToDeadline)),
    );
  });

  it.each(cases)("RiskCountdown at %s renders its reason and its day count", (_, a) => {
    const visible = text(render(<RiskCountdown assessment={a} />));
    expect(visible).toContain(t.risk.reason(a));
    expect(visible).toContain(
      a.daysToDeadline === null ? t.risk.noDeadline : toText(t.count.days(a.daysToDeadline)),
    );
  });

  it("maps the three coloured levels to the three tokens, and nothing else", () => {
    const row = (a: AtRisk) => render(<RiskRow name="N" assessment={a} />);
    expect(row(critical)).toContain("border-s-risk-1");
    expect(row(critical)).toContain("text-risk-1");
    expect(row(high)).toContain("border-s-risk-2");
    expect(row(medium)).toContain("border-s-risk-3");
    expect(row(info)).not.toMatch(RISK_CLASS);
  });

  it("gives `none` a neutral countdown with no colour and no reason", () => {
    const html = render(<RiskCountdown assessment={none} />);
    expect(html).not.toMatch(RISK_CLASS);
    expect(text(html)).toBe(toText(t.count.days(40)));
  });

  it("sets the day count's numeral in a Metric", () => {
    expect(render(<RiskRow name="N" assessment={critical} />)).toContain(
      '<bdi dir="ltr" class="font-mono">18</bdi>',
    );
  });

  it("makes the whole row a link when given an href", () => {
    const html = render(<RiskRow name="N" assessment={critical} href="/brides/b1" />);
    expect(html).toContain('href="/brides/b1"');
  });
});

describe("<RiskList>", () => {
  it("renders rows in the order given, with a count", () => {
    const html = render(
      <RiskList
        sessionsToday={2}
        items={[
          { id: "a", name: "A", assessment: critical },
          { id: "b", name: "B", assessment: high },
          { id: "c", name: "C", assessment: medium },
        ]}
      />,
    );
    expect(html.indexOf("risk-1")).toBeLessThan(html.indexOf("risk-2"));
    expect(html.indexOf("risk-2")).toBeLessThan(html.indexOf("risk-3"));
    expect(html.match(/<li/g)).toHaveLength(3);
    expect(text(html)).toContain(t.risk.sectionLabel);
  });

  it("drops rows at level none", () => {
    const html = render(
      <RiskList
        sessionsToday={2}
        items={[
          { id: "a", name: "A", assessment: critical },
          { id: "z", name: "Z", assessment: none },
        ]}
      />,
    );
    expect(html.match(/<li/g)).toHaveLength(1);
  });

  it("is exactly the §8.5 sentence when nothing is at risk", () => {
    const html = render(
      <RiskList sessionsToday={2} items={[{ id: "z", name: "Z", assessment: none }]} />,
    );
    // One sentence, no list, no image, no heading, no colour.
    expect(text(html)).toBe(t.today.allClear(2));
    expect(html).not.toMatch(/<(?:ul|li|img|svg|h\d)\b/);
    expect(html).not.toMatch(RISK_CLASS);
  });
});
