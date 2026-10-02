import type { RiskAssessment } from "@/lib/domain/risk";

import type { Phrase } from "./phrase";
import { countPhrase, countText, type CountForms } from "./plural";

/**
 * The Hebrew catalog — every product string Pinkas renders (SDD §11).
 *
 * Phase 1 is Hebrew only, so this is not here to be translated. It is here so
 * that copy lives outside components (a lint rule bans Hebrew literals under
 * `app/` and `components/`), and so that sentences are *composed* from codes
 * and operands rather than stored: the database holds `risk_reason_code` and
 * its numbers, never the sentence (§8.3).
 *
 * Plain values are strings. Copy with a variable part is a function. Copy that
 * contains a standalone quantity returns a {@link Phrase}, so the quantity can
 * be set in mono without the string layer emitting markup.
 */

/* ── Counted nouns ──────────────────────────────────────────────────────── */

const DAYS: CountForms = {
  one: "יום אחד",
  two: "יומיים",
  few: "{n} ימים",
  many: "{n} יום",
};

const SESSIONS: CountForms = {
  one: "מפגש אחד",
  few: "{n} מפגשים",
};

/* ── Risk sentences (§8.3) ──────────────────────────────────────────────── */

type AtRisk = Exclude<RiskAssessment, { level: "none" }>;

/**
 * The reason sentence for a risk verdict, composed from its code and operands.
 * The switch is exhaustive over `RiskReasonCode`: a new code in
 * `lib/domain/risk.ts` without a sentence here is a type error, not a blank
 * row on Today.
 */
function riskReason(assessment: AtRisk): string {
  switch (assessment.reasonCode) {
    case "wont_finish_in_time": {
      const n = assessment.operands.sessionsRemaining;
      const left = n === 1 ? "מפגש אחד נותר" : `${n} מפגשים נותרו`;
      return `${left} · לא ייגמר בזמן`;
    }
    case "cancelled_not_rescheduled": {
      const n = assessment.operands.staleCancellations;
      return n === 1
        ? "מפגש בוטל ולא תוזמן מחדש"
        : `${n} מפגשים בוטלו ולא תוזמנו מחדש`;
    }
    case "no_recent_session":
      return `אין מפגש מזה ${countText(assessment.operands.daysSinceLastSession, DAYS)}`;
    case "wedding_approaching": {
      const d = assessment.operands.daysToWedding;
      if (d < 0) return "תאריך החתונה עבר";
      if (d === 0) return "החתונה היום · המסלול בזמן";
      return `החתונה בעוד ${countText(d, DAYS)} · המסלול בזמן`;
    }
    default: {
      const unreachable: never = assessment;
      throw new Error(`No sentence for risk reason ${JSON.stringify(unreachable)}`);
    }
  }
}

/* ── The catalog ────────────────────────────────────────────────────────── */

export const he = {
  app: {
    /** Neutral by requirement (§6.3): the tab title names no subject matter. */
    name: "פנקס",
  },

  /** Counted quantities. */
  count: {
    /** "יום אחד" · "יומיים" · "9 ימים" · "18 יום" — numeral in mono. */
    days: (n: number): Phrase => countPhrase(n, DAYS),
    /** "מפגש אחד" · "2 מפגשים" — as prose, for sentences. */
    sessions: (n: number): string => countText(n, SESSIONS),
  },

  risk: {
    /** Section label above the risk rows on Today (plate 01). */
    sectionLabel: "דורש תשומת לב",
    reason: riskReason,
    /** Screen-reader context for the bare day count beside a risk row. */
    daysToDeadline: "עד היעד:",
    /** Stands in for the day count when the course has no deadline set. */
    noDeadline: "ללא יעד",
  },

  today: {
    title: "היום",
    /**
     * The §8.5 empty state, verbatim from the wireframe for n = 2: "הכל בזמן.
     * 2 מפגשים היום." No illustration, no greeting — one sentence confirming
     * the system checked.
     */
    allClear: (sessionsToday: number): string =>
      sessionsToday === 0
        ? "הכל בזמן. אין מפגשים היום."
        : `הכל בזמן. ${countText(sessionsToday, SESSIONS)} היום.`,
  },
} as const;

export type Catalog = typeof he;
