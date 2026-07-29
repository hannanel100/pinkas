import { Assistant, IBM_Plex_Mono, Suez_One } from "next/font/google";

/**
 * SDD §10.4 — self-hosted via next/font, subset to Hebrew + Latin.
 *
 * next/font downloads and self-hosts at build time, so there is no runtime
 * request to Google Fonts. That matters twice: it removes a render-blocking
 * third-party round trip from the 2-second budget (§18.1), and on portal routes
 * it keeps the page load out of a third party's logs (§6.3).
 *
 * Three families, each with exactly one job (§10.3). Nothing else is imported —
 * a fourth family would be a design change, not a convenience.
 */

/** Screen titles only. */
export const suezOne = Suez_One({
  subsets: ["hebrew", "latin"],
  weight: "400",
  variable: "--font-suez-one",
  display: "swap",
});

/** All prose — names, labels, sentences. */
export const assistant = Assistant({
  subsets: ["hebrew", "latin"],
  variable: "--font-assistant",
  display: "swap",
});

/**
 * Machine-readable quantities only — clock times, dates, day counts, currency,
 * progress fractions. Latin subset alone: it renders digits and currency, never
 * Hebrew prose. Rendered through <Metric>, never applied directly.
 */
export const ibmPlexMono = IBM_Plex_Mono({
  subsets: ["latin"],
  weight: ["400", "500"],
  variable: "--font-ibm-plex-mono",
  display: "swap",
});

/** Applied to <html> by both root layouts. */
export const fontVariables = [
  suezOne.variable,
  assistant.variable,
  ibmPlexMono.variable,
].join(" ");
