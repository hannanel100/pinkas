# `lib/domain/` — the pure engines

**Owning agent:** `domain` · **Design:** SDD §7 (scheduling), §8 (risk), §9 (Hebrew calendar), §14.2 (templates)

Empty by design. The scaffold establishes the directory and the lint boundary; the engines and
their interfaces are ticketed, because the type shapes are the design decision and belong to the
agent that owns them.

Expected modules, per SDD §2.4:

| Module | Design |
|---|---|
| `scheduling.ts` | §7 — backward placement from `weddingDate − bufferDays` |
| `risk.ts` | §8 — mirrors `v_course_risk`; the view stays the source of truth |
| `hebrew-calendar.ts` | §9 — the only module that reads the Hebrew/Gregorian conversion |
| `templates.ts` | §14.2 — pure rendering; unknown variables render empty |

**Invariant 4 is enforced here by `eslint.config.mjs`**, already, before any code exists: this
directory may not import from `lib/data/`, `lib/supabase/`, `next`, `react` or `node:*`, and may not
call `new Date()` or `Date.now()` — `today` is injected. That is what makes §17.2's fixture tests
possible.
