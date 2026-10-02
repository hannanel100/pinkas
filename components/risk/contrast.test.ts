import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

/**
 * SDD §18.2 / #5 — the risk tokens must meet WCAG AA at the size they are
 * actually used, and the theme must stay a closed set (invariant 7).
 *
 * The values are read from app/globals.css rather than restated here, so a
 * token that drifts back to an illegible value fails this test instead of
 * passing a stale copy of itself.
 *
 * Measured against `screen`, not `paper`: `.viewport` renders on `screen`, and
 * `paper` is the desk behind the device frame — no product text sits on it.
 */

const css = readFileSync(join(process.cwd(), "app/globals.css"), "utf8");

function colourTokens(): Map<string, string> {
  const tokens = new Map<string, string>();
  for (const match of css.matchAll(/--color-([a-z0-9-]+):\s*(#[0-9a-fA-F]{6})\s*;/g)) {
    const [, name, value] = match;
    if (name && value) tokens.set(name, value.toLowerCase());
  }
  return tokens;
}

function token(name: string): string {
  const value = colourTokens().get(name);
  if (!value) throw new Error(`--color-${name} is not defined in app/globals.css`);
  return value;
}

/** WCAG 2.x relative luminance. */
function luminance(hex: string): number {
  const channels = [1, 3, 5].map((i) => {
    const c = parseInt(hex.slice(i, i + 2), 16) / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  const [r = 0, g = 0, b = 0] = channels;
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return ((hi ?? 0) + 0.05) / ((lo ?? 0) + 0.05);
}

/**
 * 11px is below WCAG's large-text threshold (18pt, or 14pt bold), so it is
 * normal text and needs 4.5:1. §18.2: if a token fails, darken the token —
 * never enlarge the text to qualify for the 3:1 large-text threshold.
 */
const AA_NORMAL_TEXT = 4.5;

describe("risk tokens — WCAG AA on screen at 11px (#5)", () => {
  const screen = token("screen");

  it.each(["risk-1", "risk-2", "risk-3"])("%s clears 4.5:1", (name) => {
    expect(contrast(token(name), screen)).toBeGreaterThanOrEqual(AA_NORMAL_TEXT);
  });

  it("steps down in luminance with severity, so the order survives greyscale", () => {
    const [r1, r2, r3] = ["risk-1", "risk-2", "risk-3"].map((n) =>
      luminance(token(n)),
    );
    expect(r1).toBeLessThan(r2 ?? 0);
    expect(r2).toBeLessThan(r3 ?? 0);
  });

  it("graphite — the reason sentence beside the colour — clears 4.5:1", () => {
    // The reason sentence is what keeps risk from being colour-only (§18.2);
    // it is useless if it is itself illegible.
    expect(contrast(token("graphite"), screen)).toBeGreaterThanOrEqual(
      AA_NORMAL_TEXT,
    );
  });
});

describe("the colour token set is closed (invariant 7, SDD §10.2)", () => {
  it("removes Tailwind's default palette before defining anything", () => {
    expect(css).toMatch(/--color-\*:\s*initial;/);
  });

  it("defines exactly the neutrals of §10.1 and the three risk tokens", () => {
    // Adding a token means editing this list — a reviewable act, which is the
    // point. An accent colour is a design change, not a convenience.
    expect([...colourTokens().keys()].sort()).toEqual(
      [
        "graphite",
        "ink",
        "paper",
        "paper-line",
        "risk-1",
        "risk-2",
        "risk-3",
        "screen",
        "wire",
        "wire-soft",
      ].sort(),
    );
  });
});
