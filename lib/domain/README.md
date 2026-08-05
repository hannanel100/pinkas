# `lib/domain/` — the pure engines

**Owning agent:** `domain` · **Design:** SDD §7 (scheduling), §8 (risk), §9 (Hebrew calendar), §14.2 (templates)

| Module | Design |
|---|---|
| `scheduling.ts` | §7 — backward placement from `weddingDate − bufferDays` |
| `risk.ts` | §8 — mirrors `v_course_risk`; the view stays the source of truth |
| `hebrew-calendar.ts` | §9 — dates, the Hebrew/Gregorian conversion, the unavailable-day calendar |
| `templates.ts` | §14.2 — pure rendering; unknown variables render empty |

Each module has a fixture table beside it (`*.test.ts`). They run in about two seconds because
nothing here touches a database or a clock — which is the point of the boundary below.

**Invariant 4 is enforced by `eslint.config.mjs`**: this directory may not import from `lib/data/`,
`lib/supabase/`, `next`, `react` or `node:*`, and may not call `new Date()` or `Date.now()` —
`today` is injected. If a change here seems to need a database read, the read belongs in `lib/data/`
and the value belongs in the input type.

## Decisions these modules make, that the SDD left open

**A date is a branded `YYYY-MM-DD` string** (`CalendarDate` in `hebrew-calendar.ts`), and all
arithmetic runs through Rata Die day numbers. §9.4 requires civil-day arithmetic because Israel
observes DST; the brand is what stops a timestamp being passed where a date is meant.

**`risk.ts` takes the aggregate, not the raw rows.** `CourseRiskInput` mirrors the columns of
`v_course_risk`'s `agg` CTE, so the duplicated logic is exactly the view's `case` expression.
`summariseCourse` mirrors the CTE itself for callers holding cached sessions — the mirror is split
along the same seam as the view, so a change to one has an obvious counterpart in the other.

**A skip carries a discriminated reason**, not a string: `shabbat`, `yomTov`, `cholHamoed`,
`fastDay`, `blackout`, `occupied`, each with its operands. §7.6 needs the reason to survive to the
UI, and §8.3's rule applies here too — the Hebrew sentence is composed in the translation layer,
never emitted from a pure engine.

## Two Phase-1 simplifications, stated openly

Both live in `hebrew-calendar.ts` and nowhere else, so both are contained if they turn out wrong.

1. **Hebrew dates are civil dates, with no sunset rollover** (§9.3). Safe only because the deadline
   is cushioned by a two-week buffer. Never extend it to halachic times.
2. **Unavailability is evaluated at day granularity.** §9.2 describes Shabbat as Friday sunset to
   Saturday nightfall, but a Phase-1 slot carries a date and no time, so Saturday is unavailable and
   Friday is not. When sessions carry a time of day, the Friday cutoff becomes candle-lighting for
   her city — `@hebcal/core`'s `Zmanim` is pure, so that change stays inside this module.

## If you change `risk.ts`, say so about `v_course_risk`

The view in `schema.sql` is the source of truth and is owned by the `database` agent. The two must
agree tier for tier and boundary for boundary; `risk.test.ts` and `schema.test.sql` are the two
halves of that agreement.
