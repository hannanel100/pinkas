# ADR-0003 — `session_record` as a separate table, not a field permission

**Status:** Accepted · July 2026
**Relates to:** SDD §3.6, §5 · verified by `schema.test.sql`

## Context

A session has two audiences with irreconcilable access needs:

- **The bride** needs date, time, duration and location. She is unauthenticated, reaching the system through a link (SDD §6.2).
- **The instructor** additionally records which topics were covered, a private note, and a "repeat this next time" note. PRD story C3 states the requirement absolutely: *the note is never accessible to the bride.*

These notes are intimate observations about a woman's personal religious preparation. The PRD frames disclosure not as a bug but as the end of the product (§10.1).

The tempting implementation is one `session` table where the portal query selects a subset of columns. PRD §4.2 rejects this in advance, in unusually direct language: **"hiding it in the UI is a future bug."**

## Decision

Two tables:

- `session` — `scheduled_at`, `duration_minutes`, `location`, `status`. Bride-visible.
- `session_record` — `covered_topic_ids[]`, `private_note`, `needs_review_note`. Never bride-visible.

The portal reads `portal_session_view`, which selects from `session` and `course` only. **There is no join from that view to `session_record`.** The private fields are not filtered out; they are unreachable.

## Why separation beats a careful query

A column-filtered query is correct only as long as every future query stays correct. The realistic failure is mundane and well-intentioned: someone adds `select *` for debugging, or an ORM eager-loads a relation, or a developer "helpfully" exposes the topic list to the portal because a bride asked what she would be learning. Each is a one-line change that a reviewer can miss.

With separate tables, the same mistakes produce a query that returns nothing, or one that does not compile — the private data is not in scope to leak.

## Enforcement

Two assertions in `schema.test.sql`, both failing the build on drift:

1. `portal_session_view` exposes exactly `id, bride_id, order_index, scheduled_at, duration_minutes, location, status` — seven names. Widening the portal surface fails CI.
2. `private_note`, `needs_review_note` and `covered_topic_ids` appear in **exactly one relation** in the entire `public` schema.

The second assertion is the important one: it catches the leak wherever it is introduced, including in a view nobody has written yet.

A corollary in the schema: **`bride` has no notes column.** `bride` is a row the portal path legitimately reads, so a free-text field there would be the first crack in the wall. Every observation about a bride belongs to a session.

## Consequences

**Good.** The guarantee is structural rather than procedural. Reviewers do not have to be vigilant about a class of mistake that is now caught by tests.

**Costs.** A join for the instructor's own views, which is free at this data volume. Two writes when marking a session complete, wrapped in a transaction. A slightly larger schema.

## Related open question

PRD §14 asks whether the bride should see the topic list. If that answer changes, the correct implementation is a **new view** over `curriculum_snapshot` titles — never a widening of `portal_session_view`. Which topics were actually covered with this particular bride stays private regardless, because that is a record of her progress, not a syllabus.
