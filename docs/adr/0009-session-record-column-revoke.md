# ADR-0009 — Private note columns are readable only through an audited reader

**Status:** Accepted · August 2026 — settled in the #7 design challenge (2026-08-05), implemented by #34
**Relates to:** SDD §2.3, §5, §13, §16.2 · extends [ADR-0006](./0006-server-only-data-access.md) and [ADR-0003](./0003-session-record-separation.md), reverses neither

## Why this is its own record

The #7 challenge settled two contested questions. The other is [ADR-0008](./0008-today-risk-from-the-aggregate.md). This one could have been an amendment to SDD §16 instead, and that was considered. It is an ADR because it **qualifies the guarantee ADR-0006 rests on** — that the access log is "complete by construction" — and a qualification of an ADR belongs in an ADR, not in prose a reader of ADR-0006 would never be sent to. It also has two rejected alternatives that are each the obvious first move (a table-level revoke; a definer function owned by `postgres`), and both are wrong in ways that are not visible until they fail. That is exactly the kind of question this directory exists to stop being reopened.

## Context

ADR-0006 makes `lib/data/` the only door to bride data, because Postgres has no `AFTER SELECT` and a read can only be logged where it is issued. Every function in `lib/data/` writes to `access_log`; therefore every read is logged.

That argument is true of **this codebase**. It is not true of **the deployment**. `schema.sql` grants `select` on `session_record` to `authenticated`, and Supabase exposes the `public` schema through PostgREST unconditionally. A valid instructor JWT can therefore issue

```
GET /rest/v1/session_record?select=private_note
```

and read every private note in that tenant, writing **zero `access_log` rows**. RLS still enforces tenancy — this is not a cross-tenant hole, and not an active leak. What it breaks is narrower and still serious: the log PRD §10.1 requires is complete only against clients that choose to use our code. The clients that matter most are exactly the ones that do not — a stolen session, and a support engineer holding an impersonated JWT (§16.2). It is one HTTP request, with no tooling.

The previous residual-risk description named "direct psql, Studio" as the way around the door. That was wrong in the direction that mattered: the real bypass is the same door with the wrapper removed.

## Decision

Two mitigations, in priority order. **The second is the one this ADR exists for.**

**1. Primary — keep the JWT out of reach of the browser.** The instructor session cookie is set `httpOnly`, `secure`, `sameSite=lax`, path `/`. `@supabase/ssr` writes whatever options it is handed and Next's `cookies().set()` does not default to `httpOnly`, so the flags are set explicitly in `lib/supabase/` and asserted by a test that reads back the `Set-Cookie` header — the failure that matters is the library dropping a flag, not an author forgetting one. Together with removing the browser's Supabase key entirely (sign-in moves to a Server Action, SDD §2.2, §6.1), this makes the bypass require a JWT that script in the page cannot read.

**2. Backstop — `authenticated` loses `SELECT` on the three private columns.** The privilege is revoked at **column** level: `authenticated` keeps `SELECT` on `session_record`'s key and timestamp columns and loses it on `private_note`, `needs_review_note` and `covered_topic_ids`. Reads of those columns go through a `security definer` reader that writes the `access_log` row **in the same statement** as the read, so the read and its log entry cannot come apart, whatever client issued the call.

Two conditions on the reader are **not tradeable**, and each is asserted in `schema.test.sql` rather than reviewed:

* **It is owned by a dedicated `nobypassrls` role, never `postgres`,** with an empty `search_path`. A reader owned by a role that bypasses RLS buys auditability by giving up invariant 1 on the single most sensitive table in the product. The suite asserts the owner from `pg_roles`.
* **A read through it carrying tenant A's JWT returns zero rows for tenant B.** Without that assertion the change is "a hole with a log", which is worse than what it replaces.

The fix **stops at `session_record` deliberately.** `bride` and `session` remain directly readable by an `authenticated` JWT through PostgREST. The answer there is shortening the window in which a usable JWT can be obtained — mitigation 1 — not more definer readers.

## Consequences accepted

**Good.** Invariant 2 is now stated in privileges, not only in table structure: a client that never loads this codebase still cannot read a note body except through the logging reader. The revoked list is exactly the three names §5.2's second assertion already pins to one relation — one list, two assertions. And it is what makes §16.2's support attribution honest rather than conventional: with the columns revoked, an impersonated session cannot reach a note body without a log row, *whatever its claims say*.

**The access log remains incomplete for `bride` and `session`, by decision.** An `authenticated` JWT used outside the codebase can read names, phone numbers and wedding dates without a log row. That is stated here rather than implied away. It is bounded by the cookie flags, by RLS (one tenant at most), and by being the less intimate half of the data. ADR-0006's "complete by construction" should be read with this ADR beside it: complete for note bodies against any client; complete for everything else against clients that use `lib/data/`.

**The reader is a surface §5.2's assertion cannot see.** The "exactly one relation" check reads relations; a function's result columns are not a relation. The reader is therefore a second place the three names leave `session_record`, protected by its owner, its grant and its own assertions in #34 — not by §5.2. Anyone adding a second such function is adding a second unguarded surface, and should be asked why.

**Writes keep working only because the revoke is column-level** (see below). The upsert path is exercised by a test, not reasoned about.

## Alternatives rejected

**Revoke `SELECT` on the whole table.** The challenger's first proposal, and the obvious move. Rejected because it breaks writes: Postgres requires `SELECT` on any column an `UPDATE` references in its `WHERE` clause or conflict target, so `upsertSessionRecord` would fail. The column form leaves the key readable and takes away exactly the three names that matter.

**A definer reader owned by `postgres`.** The default Supabase pattern, and the one a migration written in a hurry produces. Rejected because the owner bypasses RLS: tenancy inside the function would rest on a `where` clause someone must remember — the precise failure mode ADR-0002 exists to prevent — on the table where it would cost most.

**Definer readers for `bride` and `session` as well.** Rejected as the "every read an RPC" design the #7 approach had already dismissed, arriving by another route. It moves every query into SQL functions to buy log completeness for the less sensitive tables, at the cost of the data layer ADR-0006 chose.

**Log reads with triggers.** There is no `AFTER SELECT`, and nothing trigger-shaped can stand in for the write `lib/data/` makes. Rejected as a mechanism; if any database-side logging is ever added beside it, the rule is *additional rows, never a replacement*.

**Attribute support reads by a JWT claim alone.** An `impersonated_by` claim lets `lib/data/` refuse an impersonated session on the instructor path, and it is adopted for that (§16.2). It is not a control: a holder of the service key mints the session and can omit the claim. The claim prevents misattribution by tooling we build; the column revoke is what holds against the insider §16.2 is about. The two are not halves of equal weight, and this record says so so that nobody later removes the revoke on the grounds that "the claim handles it".
