# `components/`

**Owning agent:** `frontend` · **Design:** SDD §10 (design system), §11 (RTL), §12 (screens)

| Directory | Contents |
|---|---|
| `ui/` | neutral primitives bound to the closed token set (§10) — including `<Metric>` (§10.3) |
| `risk/` | **the only components permitted to emit colour** (§10.2) |

All of them are server components. None ships client JS except `next/link` inside `<RiskRow>`.

## `ui/` — `import { … } from "@/components/ui"`

| Export | Props | Use |
|---|---|---|
| `Metric` | `children: string \| number`, `className?` (size/weight only) | A standalone machine-readable quantity: `17:00`, `12.07`, `₪2,400`, `4 / 8`. Renders `<bdi dir="ltr" class="font-mono">`. Never prose. Format the value with `format*` from `@/lib/i18n`. |
| `Phrase` | `value: Phrase`, `metricClassName?` | Renders copy from the string layer that contains a quantity — `t.count.days(18)` → mono `18`, Assistant `יום`. Only the quantity is mono; the unit is prose. |
| `SectionLabel` | `label: string`, `count?: number`, `id?` | The `<h2>` above a block, count at the inline end ("דורש תשומת לב · 3"). |

## `risk/` — `import { … } from "@/components/risk"`

Every component here takes a whole `RiskAssessment` (from `lib/domain/risk.ts`, the shape of a
`v_course_risk` row) — never a bare level — so colour cannot be rendered without the reason
sentence and the day count beside it (§18.2). Levels map to colour in `tone.ts` only: `critical` →
`risk-1`, `high` → `risk-2`, `medium` → `risk-3`; `info` and `none` are neutral.

| Export | Props | Use |
|---|---|---|
| `RiskList` | `items: { id, name, assessment, href? }[]`, `sessionsToday: number` | The first block on Today (plate 01). Rows in the order given (the view ranks them); `none` rows dropped; with none left it is exactly the §8.5 sentence "הכל בזמן. 2 מפגשים היום." and nothing else. |
| `RiskRow` | `name`, `assessment: AtRisk`, `href?` | One `<li>` of the above: colour on the inline-start edge and the day count, reason sentence underneath the name. Whole row is the tap target when `href` is set. |
| `RiskCountdown` | `assessment: RiskAssessment` | The countdown chip on the bride card (plate 02, note b1), in days. When it carries a colour, the reason sentence renders beneath it. |
| `isAtRisk`, `AtRisk` | | Narrowing helper / type for "every level except `none`". |

## The rules, and where they are enforced

**Invariant 7**, in `eslint.config.mjs`: raw hex and `rgb()`/`hsl()` are errors anywhere under
`app/` or `components/`, and the `risk-*` tokens may be referenced only inside `components/risk/`.
The theme in `app/globals.css` exposes no chromatic token except those three, so a developer
reaching for an accent colour finds that none exists. `risk/contrast.test.ts` asserts the token set
stays closed and that each risk token clears WCAG AA (4.5:1) on `screen` at its 11px size (#5).

**Invariant 8**: logical CSS properties only — `ml-*`, `pl-*`, `left-*`, `text-left` and their
physical siblings are lint errors. A Hebrew string literal under `app/` or `components/` is also a
lint error: copy lives in `lib/i18n/he.ts` and is read through `t`.
