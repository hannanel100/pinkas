import { renderToStaticMarkup as render } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { t } from "@/lib/i18n";

import { Metric, Phrase, SectionLabel } from "./index";

describe("<Metric>", () => {
  it("isolates the quantity as dir=ltr, in mono", () => {
    expect(render(<Metric>17:00</Metric>)).toBe(
      '<bdi dir="ltr" class="font-mono">17:00</bdi>',
    );
  });

  it("keeps mono and ltr when sized", () => {
    expect(render(<Metric className="text-[15px]">₪2,400</Metric>)).toBe(
      '<bdi dir="ltr" class="font-mono text-[15px]">₪2,400</bdi>',
    );
  });
});

describe("<Phrase>", () => {
  it("puts only the numeral in a Metric; the unit stays prose", () => {
    const html = render(<Phrase value={t.count.days(18)} />);
    const [numeral, unit] = t.count.days(18);
    expect(numeral).toEqual({ metric: "18" });
    expect(html).toBe(`<bdi dir="ltr" class="font-mono">18</bdi>${String(unit)}`);
  });

  it("renders a word-only count with no Metric at all", () => {
    expect(render(<Phrase value={t.count.days(2)} />)).not.toContain("<bdi");
  });
});

describe("<SectionLabel>", () => {
  it("is a heading whose count is a Metric", () => {
    expect(render(<SectionLabel id="h" label={t.risk.sectionLabel} count={3} />)).toMatch(
      /^<h2 id="h"[^>]*><span>[^<]+<\/span><bdi dir="ltr" class="font-mono">3<\/bdi><\/h2>$/,
    );
  });
});
