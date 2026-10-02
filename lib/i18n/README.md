# `lib/i18n/` — the translation layer

**Owning agent:** `frontend` · **Design:** SDD §11, §8.3, §10.3

Phase 1 is Hebrew only. This layer exists so copy lives outside components, and so sentences are
*composed* from codes and operands — the database stores `risk_reason_code` and its numbers, never
a rendered sentence (§8.3). A Hebrew literal under `app/` or `components/` is a lint error.

```ts
import { t, formatClock, formatShekels } from "@/lib/i18n";

t.app.name                    // "פנקס" — neutral by requirement (§6.3)
t.risk.reason(assessment)     // "4 מפגשים נותרו · לא ייגמר בזמן" — exhaustive over the reason codes
t.risk.sectionLabel           // "דורש תשומת לב"
t.today.allClear(2)           // "הכל בזמן. 2 מפגשים היום." — the §8.5 empty state
t.count.days(18)              // Phrase: [metric "18", " יום"] — render with <Phrase>
t.count.sessions(1)           // "מפגש אחד" — prose, for sentences
```

| Module | Contents |
|---|---|
| `he.ts` | The catalog. Strings, functions for copy with operands, `Phrase` for copy containing a standalone quantity. |
| `plural.ts` | Hebrew counting: "יום אחד", "יומיים", "9 ימים", "18 יום". `countPhrase` (numeral as metric) and `countText` (numeral as prose). |
| `phrase.ts` | `Phrase` = prose and metric segments; `fill("{n} ימים", { n: metric(9) })`; `toText` for `aria-label`s and tests. |
| `format.ts` | The strings that go *inside* a `<Metric>`: `formatClock` (Asia/Jerusalem, `17:00`), `formatDayMonth` (`12.07`), `formatDate` (`10.09.2026`), `formatShekels` (`₪2,400`), `formatFraction` (`4 / 8`). No Hebrew, no clock reads. |

**Adding copy:** add it to `he.ts`. If it has a variable part, make it a function of typed operands.
If it contains a quantity that stands alone as data, return a `Phrase`; a number inside a sentence
is prose and stays a plain string (§10.3).
