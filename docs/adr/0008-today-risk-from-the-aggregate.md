# ADR-0008 — The Today screen computes risk from the aggregate, not the verdict

**Status:** Accepted · August 2026 — settled in the #7 design challenge (2026-08-05), implemented by #35 and #7
**Relates to:** SDD §8.1, §8.4, §12.1, §15, §18.1 · extends [ADR-0006](./0006-server-only-data-access.md), reverses none

## Context

The risk tiers of SDD §8.1 exist in two places. `v_course_risk` in `schema.sql` evaluates them in SQL; `lib/domain/risk.ts` evaluates them in TypeScript. Until this decision the SDD called the view *the* source of truth and `risk.ts` a mirror "for offline use", and the obvious design for `getTodayScreen` followed from that: the `today_screen` RPC selects the view's verdict — `risk_level`, `risk_reason_code`, `days_to_deadline` — and the screen renders it.

That was the owner's opening position in #7, and it is a reasonable one. One mechanism online, the database as the arbiter, the TypeScript copy confined to the case that cannot reach the database.

**The argument that decided it appeared in neither opening position.** §15 already serves the Today screen from cache when the instructor is offline, and offline there is no database — so offline risk is *necessarily* computed by `risk.ts`. Under the verdict-from-SQL design the same screen, for the same bride, on the same morning, is ranked by SQL when she has signal and by TypeScript when she does not. Any disagreement between the two implementations — a boundary read differently, a null handled differently (#42 is exactly that), a clock read in a different timezone (#38) — surfaces as the screen changing its answer **switching on connectivity**. On the one screen whose purpose is to tell her which bride is about to miss the deadline, that is the worst place for an inconsistency to live: she cannot see why, and nothing about it looks like a bug.

The divergence the owner would have cited *against* moving the verdict into TypeScript was therefore already present. Moving it is what removes it.

## Decision

**The Today screen's risk verdict is computed by `assessRisk()` in `lib/domain/risk.ts`, online and offline alike.**

* The `today_screen` RPC returns `v_course_risk`'s **aggregate** columns — `course_id`, `bride_id`, `sessions_remaining`, `sessions_done`, `last_done_at`, `stale_cancellations`, `target_end_date`, `wedding_date` — and does not return `risk_level`, `risk_reason_code` or `days_to_deadline`. No new view: the view's projection already exposes every `agg` field, and its `course.status = 'active'` filter comes with it.
* `lib/data/today.ts` maps each row to `CourseRiskInput`, injects `today` (invariant 4), and calls `assessRisk()`. Offline, the cached rows go through `summariseCourse()` to the same function.
* Each at-risk row carries both the input and the assessment, so the renderer has every operand the reason sentence needs — including `lastDoneOn` for the `no_recent_session` row, which wireframe plate 01 renders as a Hebrew date (*אין מפגש מאז 2 באב*) beside its day count. The verdict-only shape carried neither.
* **`v_course_risk` narrows to two roles:** the source of truth for the nightly job (§8.4), which runs inside the database and cannot call TypeScript, and the SQL half of the tier-for-tier agreement that `schema.test.sql` and `risk.test.ts` assert between them.

The single round trip of §18.1 and invariant 10 is unchanged — only the select list differs — and so is the atomic `access_log` fan-out inside the same statement.

## Consequences accepted

All three were named in the exchange and conceded by both sides before the decision was taken, not discovered after it.

**1. It holds for four tiers, not five.** `stale_cancellations` is computed inside the view's `agg` CTE, against `now()`, with the 7-day threshold embedded in the SQL. It arrives at `risk.ts` already counted. Online, the `high` tier's threshold is therefore still applied by the database; offline, `summariseCourse()` applies it from cached rows. **`high` can still differ across connectivity.** Closing that would mean returning every session row to the server so `risk.ts` could count them itself, which defeats the aggregation the 2-second budget depends on. The online/offline argument above is true of `critical`, `medium`, `info` and `none`, and is stated here as true of those four only.

**2. `risk.ts` escalates no earlier than the view — up to a few hours later at the boundary.** The view compares timestamps (`last_done_at < now() - 21 days`), so its answer changes partway through the boundary day; `risk.ts` works in civil days (§9.4) and takes the strictly-greater reading, so a session done exactly 21 calendar days ago is not yet `medium`. For a deadline product, *later* escalation is the less-safe direction, and it is accepted on the same ground §9.3 already uses: a one-day boundary error cannot produce a wrong decision at this resolution, because the deadline is cushioned by a two-week buffer (§7.2). This is not a new tolerance; it is the existing one, now applied to the online screen as well as the offline one.

> **Resolved by #38 (migration 0003).** The view now compares Israeli civil dates through `course_risk(jerusalem_date(now()))`, so it and `risk.ts` agree on the boundary day itself. This consequence no longer applies; it is kept as the record of what was accepted at the time.

**3. `risk.ts` becomes load-bearing for an online screen.** §8.1 previously gave it the lighter role of an offline mirror. It is now the code that ranks the product's home screen every morning. Its fixture table (§17.2) is therefore a release gate for C1 and C6, not a convenience, and a change to it is a change to what every instructor sees on connecting — not only on losing signal. The `domain` agent owns that consequence.

**And one that follows from them.** The view and `risk.ts` must still agree tier for tier, but the *place* a disagreement shows up moves. Before this decision a divergence made Today disagree with itself across connectivity; after it, a divergence makes the nightly notification (Phase 2) disagree with the screen she opens in the morning. That is better — two surfaces, not one — but it is still a defect, and the agreement between `schema.test.sql` and `risk.test.ts` remains the contract that prevents it. #42's null-deadline divergence, for instance, no longer reaches Today at all; it still reaches the nightly job until #42 lands.

## Alternatives rejected

**Return the verdict from SQL (the original proposal).** Keeps one implementation on the online path, and makes the screen's answer depend on whether she has signal. Also leaves `days_to_deadline` computed against the database's clock rather than an injected `today`, which is the UTC defect #38 records, and leaves the `no_recent_session` row without the date it renders. Rejected for the reason in the Context; the other two are corroboration, not the argument.

**Compute `stale_cancellations` in TypeScript as well, to make it five of five.** Requires every session of every active course in the response, so that `risk.ts` can find cancellations and their reschedules itself. Rejected: it trades the aggregation — and with it the §18.1 budget on cellular — for consistency on one tier whose boundary is seven days wide.

**Drop `v_course_risk` and make `risk.ts` the only implementation.** Not argued in the exchange; recorded because it is the next question anyone will ask. Phase 1's only job runs in-database via `pg_cron` (§2.1, §2.3 Path 3), with no user and no key outside Postgres. Moving it to TypeScript means a Route Handler reading every tenant's courses with the service role — widening exactly the key invariant 5 confines — for a notification feature that does not ship until Phase 2. The view also gives `schema.test.sql` something to pin the tiers against under real RLS. If the job ever moves out of the database for other reasons, revisit this.
