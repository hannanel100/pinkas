# Pinkas — Software Design Document

**Version:** 0.1
**Date:** July 2026
**Status:** Design for Phase 1. Phases 2–3 appear only where they constrain Phase 1.
**Inputs:** [`PRD.md`](./PRD.md) (Hebrew, v0.1) · [`wireframes.html`](./wireframes.html) (4 screens, 19 annotations)

> The PRD is the source of truth for *what* and *why*. This document is the source of truth for *how*. Where the two disagree, the PRD wins on product intent and this document wins on mechanism — except where noted in [§20](#20-where-this-document-pushes-back), which lists the four places the design deliberately does not do what the PRD asked.

---

## Table of contents

| § | Section | § | Section |
|---|---|---|---|
| 1 | [Scope and traceability](#1-scope-and-traceability) | 11 | [RTL as the default direction](#11-rtl-as-the-default-direction) |
| 2 | [Architecture](#2-architecture) | 12 | [Screens and components](#12-screens-and-components) |
| 3 | [Data model](#3-data-model) | 13 | [Server data-access layer](#13-server-data-access-layer) |
| 4 | [Multi-tenancy and RLS](#4-multi-tenancy-and-rls) | 14 | [WhatsApp integration](#14-whatsapp-integration) |
| 5 | [The private/public boundary](#5-the-privatepublic-boundary) | 15 | [Offline and PWA](#15-offline-and-pwa) |
| 6 | [Authentication](#6-authentication) | 16 | [Security, privacy, retention](#16-security-privacy-retention) |
| 7 | [The backward-scheduling engine](#7-the-backward-scheduling-engine) | 17 | [Testing strategy](#17-testing-strategy) |
| 8 | [The risk engine](#8-the-risk-engine) | 18 | [Performance and accessibility](#18-performance-and-accessibility-budgets) |
| 9 | [Hebrew calendar and dates](#9-hebrew-calendar-and-dates) | 19 | [Forward compatibility](#19-forward-compatibility-phases-23) |
| 10 | [Design system](#10-design-system) | 20 | [Push-back and open questions](#20-where-this-document-pushes-back) |

---

## 1. Scope and traceability

### 1.1 What Phase 1 is

PRD §13 שלב 1 defines the milestone as: *one real instructor manages one complete course end to end.* Everything below serves that sentence. The target is 10 beta users acquired by personal referral.

### 1.2 Story traceability

Every story in PRD §6 is accounted for. "P1" ships in Phase 1; "P2"/"P3" are deferred but the column on the right records what Phase 1 must already do so the deferral stays cheap.

| Story | Summary | Phase | Designed in | Phase-1 obligation |
|---|---|---|---|---|
| A1 | Instructor signup ≤60s, no card | P1 | §6.1 | — |
| A2 | Curriculum builder, drag to reorder | P1 | §3.3 | Deferrable unique constraint on `(curriculum_id, order_index)` |
| A3 | Duplicate a curriculum, copy independent | P1 | §3.3 | — |
| A4 | Default course price | P1 | §3.2 | — |
| B1 | Add bride; date in Hebrew or Gregorian, shown in both | P1 | §9 | — |
| B2 | Choose curriculum → system proposes a backward schedule | P1 | §7 | — |
| B3 | Referral source, free text + accumulating list | P1 | §3.4 | — |
| B4 | Warn immediately if there is not enough time | P1 | §7.4 | — |
| C1 | Today screen as home | P1 | §12.1 | — |
| C2 | Mark session done, tick covered topics | P1 | §3.6 | — |
| C3 | Private note, never reachable by the bride | P1 | §5 | — |
| C4 | "Repeat this" surfaces at the next session | P1 | §5, §12.2 | — |
| C5 | Reschedule → recompute, warn if deadline breaks | P1 | §7.5 | — |
| C6 | Who is at risk of not finishing | P1 | §8 | — |
| D1 | Send a reminder for tomorrow's session | P1 | §14 | — |
| D2 | Edit my own message templates | **P2** | §14.2 | Ship seeded system templates; `message_template` table exists |
| D3 | Send the bride a portal link | **P2** | §6.2 | `portal_token_hash` / `portal_expires_at` columns exist |
| D4 | See what was sent and when | P1 ⚠️ | §14.3 | Partial — see §20.2 |
| E1 | Bride enters by link, no signup | **P2** | §6.2 | — |
| E2 | Bride sees schedule and next session, no notes | **P2** | §5 | `portal_session_view` exists and is tested |
| E3 | Bride downloads shared materials | **P2** | §3.7 | `material.shared_with_bride` exists |
| E4 | Access closes after the wedding | **P2** | §6.2 | `portal_expires_at` exists |
| F1 | Record a payment received | P1 | §3.8 | — |
| F2 | See who owes what | P1 | §12.1 | — |
| F3 | Religious council pays part | **P2** | §3.8 | `payer` enum already models it |
| F4 | Export a yearly summary as CSV | P1 | §16.4 | — |
| G1 | Produce a completion certificate (PDF) | **P2** | — | — |
| G2 | Mark a course complete → bride archived | P1 | §3.5 | — |
| G3 | Post-wedding follow-up reminder | **P2** | — | — |

**Phase 1 = 20 stories. Deferred = 9.**

### 1.3 Explicitly out of scope

Per PRD §5, and unchanged: teams/multiple instructors per account, a shared curriculum library, card processing, automatic invoicing, analytics, a native app, in-app chat, languages other than Hebrew.

---

## 2. Architecture

### 2.1 Stack

| Layer | Choice | Why |
|---|---|---|
| Client | Next.js (App Router), React, TypeScript, PWA | One codebase, server rendering for the 2s budget (§18), installable without an app store (PRD §10.3) |
| Styling | Tailwind with a closed token set | Enforces the single-colour rule in code, not in review (§10) |
| Server | Next.js Route Handlers + Server Actions on Vercel | No separate API tier to operate; a lean team is a stated constraint (PRD §11.3) |
| Database | Supabase Postgres, RLS enforced | RLS is a PRD hard requirement (§7.1), and is native here — [ADR-0002](./adr/0002-rls-as-the-isolation-boundary.md) |
| Auth | Supabase Auth (phone OTP) | Matches the persona's habits (PRD §3.1) |
| Files | Supabase Storage, private buckets, signed URLs | §3.7 |
| Jobs | `pg_cron` | Nightly risk notifications only (§8.4) |
| Hebrew calendar | `@hebcal/core` | §9 |

Rejected alternatives are recorded in [ADR-0001](./adr/0001-nextjs-supabase.md).

### 2.2 The three access paths

The whole security design follows from there being exactly three ways data is reached, with different trust levels. Nothing else may talk to the database.

```
┌── PATH 1 · INSTRUCTOR (authenticated, high trust) ─────────────────┐
│  Browser ─→ Server Action / Route Handler                          │
│               └─ Supabase client carrying THE USER'S JWT           │
│                    └─ RLS active: tenant_id = auth.uid()           │
│  Reaches: everything belonging to that tenant, incl. session_record│
└────────────────────────────────────────────────────────────────────┘

┌── PATH 2 · BRIDE PORTAL (unauthenticated, low trust) ──────────────┐
│  Browser ─→ /p/[token] Route Handler                               │
│               └─ hash the token, look up the bride                 │
│                    └─ service-role client, EXPLICIT bride_id filter │
│                         └─ reads portal_session_view ONLY           │
│  Reaches: date, time, place, shared materials. Nothing else.       │
└────────────────────────────────────────────────────────────────────┘

┌── PATH 3 · JOBS (no user, system trust) ──────────────────────────┐
│  pg_cron ─→ SQL in-database, or a Route Handler with a job secret  │
│  Reaches: aggregates for notifications. Never returns note bodies. │
└────────────────────────────────────────────────────────────────────┘
```

Two rules make this hold, and both are testable:

1. **The browser never holds a Supabase client for bride data.** All reads go through `lib/data/` (§13). This is not a style preference — the access log in PRD §10.1 cannot otherwise be written correctly.
2. **The service-role key is confined to Path 2 and Path 3.** It never appears in a code path that accepts arbitrary user input; the only untrusted input it ever sees is a portal token, which is hashed before use.

### 2.3 Module layout

```
app/
  (instructor)/            Path 1 — authenticated screens
    today/                 plate 01
    brides/[id]/           plate 02
    courses/[id]/schedule/ plate 03
    curricula/ calendar/ finances/ settings/
  p/[token]/               Path 2 — portal, plate 04. No shared layout with above.
lib/
  domain/                  PURE. No I/O, no imports from lib/data or supabase.
    scheduling.ts          §7
    risk.ts                §8
    hebrew-calendar.ts     §9
    templates.ts           §14.2
  data/                    Server-only. The single chokepoint. §13
  supabase/                client factories: user-jwt | service-role | job
components/
  ui/                      primitives bound to the token set (§10)
  risk/                    the only components allowed to emit colour
```

`lib/domain/` importing anything from `lib/data/` or `lib/supabase/` is a lint error. Keeping the two engines pure is what makes §17's fixture tests possible.

---

## 3. Data model

The authoritative, executable schema is **[`schema.sql`](./schema.sql)** — it becomes `supabase/migrations/0001_init.sql` unchanged. Its verification suite is **[`schema.test.sql`](./schema.test.sql)**. Both have been executed against Postgres 16; see §17.1 for how to run them. This section explains the model and the decisions inside it; it does not restate the DDL, so that the two cannot drift.

### 3.1 Conventions

* `tenant_id uuid` on every tenant-owned table, referencing `instructor(id)`, `on delete cascade`.
* `created_at` / `updated_at` on every table, `updated_at` maintained by the shared `set_updated_at()` trigger.
* `deleted_at timestamptz` soft delete everywhere, with hard deletion available on request (§16.4). Partial indexes are all `where deleted_at is null` so the soft-delete predicate is served, not scanned.
* All instants are `timestamptz`; all civil dates are `date`. Display timezone is `Asia/Jerusalem` (§9.3).
* Money is `numeric(10,2)` with an explicit `currency`. Never floating point.

### 3.2 `instructor` — the tenant

`instructor.id` *is* the `tenant_id`, and equals `auth.users.id`. There is deliberately no separate tenant table: in Phase 1 one instructor is one account, and inventing an `organization` indirection now would be speculative. §19.1 explains why adding it later is a data migration rather than a schema redesign.

Carries `default_price` (A4), `default_buffer_days` (default 14, §7.2), `timezone`, `locale`.

### 3.3 `curriculum` and `curriculum_topic`

A curriculum is a **template**. Topics are ordered by `order_index`.

Drag-to-reorder (A2) rewrites many rows in one statement, which transiently violates uniqueness on `(curriculum_id, order_index)`. The constraint is therefore `deferrable initially deferred` — it is checked at commit, so a single `UPDATE ... FROM (VALUES ...)` reorder succeeds while a genuinely duplicated order still fails. *Consequence to remember:* a deferrable unique constraint cannot serve as an `ON CONFLICT` arbiter, so upserts on topics must target the primary key.

Duplicating a curriculum (A3) is a plain row copy — new ids, no back-reference to the source. "The copy is entirely independent of the original" is the acceptance criterion, and shared rows would violate it.

### 3.4 `bride`

Holds identity, contact, `wedding_date` (+ `wedding_date_source`, §9.1), `referral_source` (B3 — free text; the "accumulating list" is a `SELECT DISTINCT` over the tenant's own prior values, not a lookup table), lifecycle `status`, and the portal token fields (§6.2).

**`bride` has no notes column, deliberately.** Every free-text observation about a bride belongs to a session, in `session_record` (§5). A note field here would be the first crack in the private/public wall, because `bride` is a row the portal path legitimately needs to read.

### 3.5 `course` — a curriculum instance for one bride

Carries `curriculum_snapshot jsonb`, frozen at creation ([ADR-0004](./adr/0004-curriculum-snapshot.md)), `buffer_days`, `target_end_date` (the effective deadline, §7.2), `agreed_price`, and `status`. G2 ("mark complete → archive") is `status = 'completed'` plus `completed_at`.

`curriculum_id` is `on delete set null`: deleting a template must never destroy the history of courses taught from it. The snapshot means nothing is lost when it happens.

### 3.6 `session` and `session_record`

Split in two, because they have different audiences. This is the single most important decision in the schema — see §5 and [ADR-0003](./adr/0003-session-record-separation.md).

* `session` — `scheduled_at`, `duration_minutes`, `location`, `status`. Bride-visible.
* `session_record` — `covered_topic_ids[]` (C2), `private_note` (C3), `needs_review_note` (C4). Never bride-visible, by construction.

Two fields carry design weight:

* **`scheduled_at` is nullable.** `NULL` means *not yet scheduled* — a legitimate state the wireframe names explicitly ("טרם נקבע", plate 02 note 5). The system does not force everything to be planned up front; an unscheduled session near the deadline is what generates risk (§8).
* **`is_pinned`** marks a slot the instructor placed by hand. Recomputation moves unpinned slots around it (§7.5). This is the schema-level expression of wireframe note c4: *the algorithm proposes, it does not decide.*

`rescheduled_from_session_id` links a replacement to what it replaced, which is how §8 distinguishes "cancelled and rebooked" from "cancelled and forgotten". A cancelled session is never deleted — wireframe note b4: it is history, not noise, and it explains why the course slipped.

### 3.7 `material`

Files (Supabase Storage `storage_path`) or links (`url`), enforced mutually exclusive by a `CHECK`. `shared_with_bride` gates portal visibility (E3). Files are served to the portal as short-lived signed URLs generated per request — the storage path is never handed to the browser.

### 3.8 `payment`

`amount`, `method`, `payer`, `paid_at`, `receipt_number`. F3 (a religious council paying part) needs no new schema in Phase 2 because `payer` already enumerates it and payments are already many-per-course — only the UI is deferred.

There is no `invoice` table. PRD §5 puts automatic invoicing out of scope; §19.3 notes what integrating Green Invoice would add.

### 3.9 `message_template` and `message_log`

Templates store `body` only. **Variables are parsed from the body (`{{bride_name}}`, `{{date}}`, `{{time}}`, `{{location}}`) rather than stored in a column** — a stored variable list is a denormalisation that can disagree with the text it describes. §14.2.

`message_log` records what was *composed*. See §14.3 and §20.2 for why that word, and not "sent".

### 3.10 `blackout_date`

Instructor-declared unavailability, distinct from calendar-derived skips. The scheduling engine treats both as unavailable but reports them with different reasons, because the bride-facing explanation differs ("skipped — Tisha B'Av" vs "skipped — unavailable").

### 3.11 `access_log`

Append-only. Required by PRD §10.1 ("a access log for every viewing of bride data"). Two deliberate properties:

* **No foreign key to `bride`.** The log must outlive hard deletion of the data it describes, or the erasure of a bride destroys the evidence that she was accessed.
* **Identifiers and actions only — never content.** A log that quoted note bodies would recreate, in a table nobody thought to protect, exactly the data §16 exists to guard.

Writing it correctly is the reason for §13.

---

## 4. Multi-tenancy and RLS

### 4.1 The policy

Every tenant-owned table carries the same policy shape, verified in `schema.test.sql`:

```sql
create policy bride_tenant on bride
  for all to authenticated
  using      (tenant_id = auth.uid())
  with check (tenant_id = auth.uid());
```

`USING` controls what is readable and updatable; `WITH CHECK` stops a tenant from *writing a row attributed to someone else*. Both are necessary — omitting `WITH CHECK` leaves an authenticated user able to insert rows into another tenant. The test suite asserts that such an insert is rejected.

`access_log` is the exception: `INSERT` and `SELECT` for the owning tenant, and no `UPDATE`/`DELETE` policy at all, so an instructor cannot erase her own audit trail.

### 4.2 Views must be `security_invoker`

**This was verified experimentally, and it matters more than it looks.**

A Postgres view executes with the *view owner's* privileges by default. A view created by the migration role therefore bypasses the RLS of whoever queries it. Running the identical view definition both ways against the test fixture:

| View definition | Rows visible to tenant A |
|---|---|
| `with (security_invoker = on)` | 13 — tenant A's sessions only ✅ |
| default (`security_definer` semantics) | **14 — tenant A's, plus one row belonging to tenant B** ❌ |

One leaked row is the whole failure. Both views in `schema.sql` are declared `with (security_invoker = on)`, and §17.1's suite asserts the flag is still set, so removing it fails the build rather than quietly cross-wiring tenants.

This is a general rule for the project: **every view added later must declare `security_invoker = on`.** RLS on the base tables does not save you.

### 4.3 Why RLS and not application-level scoping

PRD §7.1 requires isolation "at the DB level, **not** at the ORM level". The reasoning is that ORM scoping is a filter a developer must remember on every query, and the failure mode of forgetting is silent cross-tenant disclosure. RLS fails closed instead: a missing `tenant_id` predicate returns nothing rather than everything. [ADR-0002](./adr/0002-rls-as-the-isolation-boundary.md).

RLS is defence in depth, not the only defence — §13's data layer also scopes queries. The point is that both must fail before data leaks.

---

## 5. The private/public boundary

The product's central promise, stated in PRD §4.2 and §7.3.ב and repeated in the wireframes: *what the bride sees lives in a different table from the instructor's notes. Hiding it in the UI is a future bug.*

### 5.1 Mechanism

| | Instructor | Bride portal |
|---|---|---|
| Reads | every table, RLS-scoped | `portal_session_view` + shared `material` rows |
| Sees | `private_note`, `needs_review_note`, `covered_topic_ids` | date, time, duration, location, session number, status |
| Path | Path 1 (§2.2) | Path 2 (§2.2) |

`portal_session_view` exposes exactly seven columns:

```
id, bride_id, order_index, scheduled_at, duration_minutes, location, status
```

There is no join from that view to `session_record`. The private fields are not filtered out — they are *not reachable*.

### 5.2 The test is the contract

Two assertions in `schema.test.sql` protect this, and both fail loudly on drift:

1. The view's column list equals that seven-name string exactly. Adding a column to the portal surface — the plausible future mistake, made by someone helpfully "exposing the topic list" — fails CI.
2. `private_note`, `needs_review_note` and `covered_topic_ids` appear in **exactly one** relation across the whole `public` schema. Any new view or table that surfaces them anywhere fails CI.

Assertion 2 is the more valuable one, because it catches the leak at whatever new relation introduces it, not only at the view we already know about.

### 5.3 The related open question

PRD §14 asks whether the bride should see the *topic list* or only dates. This design answers **dates only** for Phase 1, which is also what wireframe plate 04 shows ("אין תצוגת מסלול, אין רשימת נושאים — אלה לא שלה"). If that answer changes, the correct implementation is a **new view** exposing topic titles from `curriculum_snapshot`, never a widening of `portal_session_view` — the topic titles are curriculum content, and `covered_topic_ids` (which topics were actually covered with this bride) remains private regardless.

---

## 6. Authentication

### 6.1 Instructor

Supabase Auth, **phone OTP primary**, email as fallback and recovery. The persona (PRD §3.1) already lives in WhatsApp and Bit; a phone code is the flow she has used a hundred times. Story A1 requires signup under 60 seconds with no credit card, which means no email verification round-trip on the critical path.

On first sign-in, a transaction creates the `instructor` row (`id = auth.users.id`) and seeds the system message templates (§14.2), so D1 works before the instructor has ever visited settings.

**App lock.** WebAuthn platform authenticator (Face/Touch/device biometric) gating an already-authenticated session, with cached data cleared from memory on lock. Motivated by PRD §3.1 and §10.1: *she hands the phone to her children.* Stated honestly — this is a shoulder-surfing and casual-access defence, not a cryptographic one; the session token still exists on the device. It is not a substitute for §16's controls.

### 6.2 Bride portal

The bride will not create an account, will not remember a password, and will not install anything (PRD §3.3). Access is a link. Design ([ADR-0005](./adr/0005-hashed-portal-tokens.md)):

| Property | Decision |
|---|---|
| Token | 32 random bytes, base64url, generated with a CSPRNG |
| Storage | **SHA-256 hash only**, in `bride.portal_token_hash`. The plaintext token exists once, in the response that creates it |
| Lookup | Hash the incoming token, look up by hash — an indexed equality match, so no timing signal from the query |
| Expiry | `portal_expires_at`, default `wedding_date + 14 days` (E4) |
| Revocation | Null the hash; regeneration issues a new token and invalidates the old |
| Rate limit | Per-IP and per-token-prefix, on the route |
| Indexing | `noindex, nofollow`, and `Referrer-Policy: no-referrer` so the token never leaks through an outbound link |

Storing the hash rather than the token means a database disclosure does not hand the attacker working portal links. This costs nothing — the token is never displayed again after issuance, only re-sent by regenerating.

**The expiry date is shown to the bride** ("הקישור פעיל עד 10.09", plate 04 note 4). That makes it a promise rather than a hidden policy, which is why it is a column with a value and not a constant in code.

### 6.3 Discretion requirements

PRD §3.3 and §10 make discretion functional, not cosmetic — her phone is not always private. Concretely, for the portal:

* Neutral `<title>` and PWA name; no term identifying the subject matter.
* No push notifications with body previews.
* No identifying words in URL paths, meta tags, or Open Graph data.
* No third-party scripts or analytics on portal routes at all — nothing that would place the URL in another party's logs.

Fonts are self-hosted (§10.4) partly for this reason: a runtime request to Google Fonts from a portal page puts the page load in a third-party log.

---

## 7. The backward-scheduling engine

PRD §9 calls this "the logic that justifies the system". It lives in `lib/domain/scheduling.ts` as a **pure function** — no I/O, no clock access except an injected `today` — which is what makes the fixture tests in §17.2 possible.

### 7.1 Signature

```ts
export function proposeSchedule(input: ScheduleInput): ScheduleProposal;

type ScheduleInput = {
  today:         CalendarDate;
  weddingDate:   CalendarDate;
  sessionCount:  number;
  cadence:       { kind: 'perWeek'; n: number } | { kind: 'everyNDays'; n: number };
  earliestStart: CalendarDate;
  bufferDays:    number;          // §7.2
  blackouts:     DateRange[];     // blackout_date rows
  pinned:        PinnedSlot[];    // sessions with is_pinned
};

type ScheduleProposal = {
  slots:       Slot[];
  skips:       Skip[];            // §7.3 — surfaced, never silent
  feasibility: Feasibility;       // §7.4 — never a bare complaint
};
```

### 7.2 The buffer

```
effectiveDeadline = weddingDate − bufferDays        (default 14)
```

The buffer exists because **the last session must land before the immersion, not before the ceremony** (PRD §9, plate 03 note 1). It is `course.buffer_days`, per-course and instructor-editable, with the instructor's `default_buffer_days` as the initial value — because there is genuine variation in custom here and the product's stated position (PRD §4.5) is that it hosts practice rather than ruling on it. The wireframe shows it as a visible, editable field for the same reason.

PRD §14 asks what the right buffer is. The design's answer is that **this is not a question the product should answer** — 14 days is a default, the field is editable, and the value is remembered per instructor after she first changes it.

### 7.3 Algorithm

1. Compute `effectiveDeadline`.
2. Build the unavailable-day set over `[earliestStart, effectiveDeadline]`:
   * **Shabbat** — Friday sunset to Saturday nightfall (§9.2).
   * **Yom Tov and chol hamoed** as configured, **fast days**, from `@hebcal/core`.
   * **`blackout_date`** rows for this tenant.
3. Place pinned slots first; they are immovable.
4. Fill remaining sessions **backward from `effectiveDeadline`** at the requested cadence, stepping over unavailable days and recording each step-over as a `Skip`.
5. If the walk runs past `earliestStart` before all sessions are placed, the schedule is infeasible — compute a remedy (§7.4).
6. Assign topics from `curriculum_snapshot` in order.

Backward placement, not forward, is the whole point: it anchors on the constraint that cannot move.

### 7.4 Warnings must carry a remedy

Wireframe note c2 is unusually specific and worth honouring literally: *"'Too tight' alone is a complaint. 'Suggestion: two sessions a week' is help. A warning with no way out is a product bug."*

That is encoded in the type, so it cannot be forgotten in a future screen:

```ts
type Feasibility =
  | { status: 'ok' }
  | { status: 'tight';      message: string; remedy: Remedy }   // fits, no slack
  | { status: 'infeasible'; message: string; remedy: Remedy };  // does not fit

type Remedy =
  | { kind: 'increaseCadence'; perWeek: number; forWeeks: number }
  | { kind: 'startEarlier';    date: CalendarDate }
  | { kind: 'reduceBuffer';    days: number }
  | { kind: 'reduceSessions';  to: number };
```

`remedy` is non-optional on both non-`ok` variants. **A warning without a way out is a type error, not a copy review.** Remedies are ranked cheapest-first: raising cadence before shortening the buffer, and shortening the buffer before dropping content.

This satisfies B4 (warn at add time) and is the same computation, not a second one.

### 7.5 Recomputation (C5)

Triggered by: rescheduling or cancelling a session, changing the wedding date, changing the buffer, or adding a blackout that collides.

Rules:
* **Completed sessions never move.**
* **Pinned sessions never move.** Everything else reflows around them.
* Recomputation returns a proposal; it does not silently write. The instructor confirms, exactly as at creation — plate 03 gives "ערוך ידנית" the same visual weight as "אשר לוז", and note c4 explains why: *a veteran instructor knows things about this bride that the system does not, and she will abandon a product that argues with her.*
* If recomputation makes the course infeasible, the result is a `Feasibility` with a remedy, and the course starts ranking critical in §8 immediately.

### 7.6 Skips are shown, not hidden

Every skipped date stays in the output with its reason, and the UI renders it struck through with the reason beside it (plate 03). Note c3: *otherwise she will think the system made a mistake.* A silently-skipped Tisha B'Av looks like a bug; a visible "skipped · Tisha B'Av" looks like competence.

---

## 8. The risk engine

The Today screen's ranking (PRD §9, plate 01) — the product's core claim.

### 8.1 Tiers

Implemented in `v_course_risk` (in `schema.sql`) and mirrored by a pure TS function in `lib/domain/risk.ts` for offline use. All five tiers are asserted by `schema.test.sql`.

| Level | Condition | `risk_reason_code` |
|---|---|---|
| `critical` | sessions remaining > whole weeks to the effective deadline | `wont_finish_in_time` |
| `high` | a session was cancelled >7 days ago and never rescheduled | `cancelled_not_rescheduled` |
| `medium` | >21 days since the last completed session | `no_recent_session` |
| `info` | wedding within 30 days, course on track | `wedding_approaching` |
| `none` | — | `null` |

Evaluated in that order; the first match wins.

### 8.2 Computed on read, never stored

`v_course_risk` is a view. The ranking is derived at query time from sessions and dates, so it cannot be stale — there is no job whose failure silently leaves the Today screen showing yesterday's truth. Given the data volume (PRD §3: 10–20 brides per instructor, 50+ for the professional persona), this is comfortably cheap; the supporting indexes are in `schema.sql`.

### 8.3 The reason code is the feature

`risk_reason_code` exists because the wireframe demands an explanation, not a number. Note a3: *"18 days" alone is a number. "4 sessions left · won't finish in time" is a decision.*

The UI renders the code plus its operands into that sentence. The code is machine-readable and language-independent; the sentence is Hebrew and lives in the translation layer. Never store the rendered sentence.

### 8.4 The nightly job

`pg_cron` evaluates the same view nightly **only to drive notifications** (Phase 2). It does not populate the screen. Two mechanisms, one source of truth: the view.

### 8.5 Empty state

Specified verbatim in the wireframe and worth implementing exactly: *"הכל בזמן. 2 מפגשים היום."* — no illustration, no greeting. One sentence confirming the system checked. The absence of alarm is information, and it should read as a result, not as an empty container.

---

## 9. Hebrew calendar and dates

### 9.1 Storage

`wedding_date date` is canonical and **always Gregorian**. `wedding_date_source calendar_system` records which calendar the instructor actually typed.

Storing the source matters for B1 ("entered as Gregorian or Hebrew, displayed as both"): a wedding given as כ״ב באב should render primarily as כ״ב באב in her UI, because that is how she and the bride discuss it. Both are always displayed; the source decides emphasis, not availability. Converting on input and discarding the source would lose that.

### 9.2 Shabbat and Yom Tov boundaries

Halachic days run sunset to nightfall, so "Saturday" is not a calendar day. For **scheduling** (§7.3), the engine treats Friday evening through Saturday night as unavailable, using `@hebcal/core` candle-lighting and havdalah times for the instructor's city, with a conservative default location when none is set.

### 9.3 The Phase-1 simplification, stated openly

**Hebrew calendar *dates* are treated as civil dates with no sunset rollover.** A wedding on כ״ב באב maps to one Gregorian date, not to "after sunset on the 21st".

This is safe here because the wedding date drives a deadline measured in days and cushioned by a two-week buffer (§7.2); a one-day boundary error cannot produce a wrong decision at that resolution. It would *not* be safe for anything computing halachic times directly.

If this proves wrong, the change is contained: `wedding_date` gains a companion `wedding_date_after_sunset boolean`, and only `lib/domain/hebrew-calendar.ts` changes. Nothing else reads the conversion.

### 9.4 Timezone

Everything is `Asia/Jerusalem`. `timestamptz` throughout, converted at the edge. Israel observes DST, so date arithmetic that crosses a transition must be done in civil days (`date` arithmetic), never by adding 86 400-second multiples — the scheduling engine works in `CalendarDate`, not epoch seconds, specifically to make this class of bug unrepresentable.

### 9.5 Seasonality

PRD §10.2 and §11.1 note periods when weddings do not occur (Sefirat HaOmer, Bein HaMetzarim). Phase 1 does not model these as scheduling rules — they suppress *weddings*, not *lessons*, and instruction continues through them. They matter to cash-flow display (Phase 2) and to the business model, not to the engine.

---

## 10. Design system

The wireframes are unusually prescriptive, and the annotations state design *rules*, not just appearance. This section turns them into enforceable code.

### 10.1 Tokens, taken verbatim from the sheet

| Token | Value | Role |
|---|---|---|
| `paper` | `#EBEDF0` | sheet background |
| `paper-line` | `#DDE1E7` | grid rule |
| `ink` | `#101418` | primary text, filled controls |
| `graphite` | `#6B7280` | secondary text |
| `wire` | `#C9CDD4` | borders |
| `wire-soft` | `#E4E7EB` | dividers, inactive fills |
| `screen` | `#FFFFFF` | surface |
| `risk.1` | `#A81E32` | critical |
| `risk.2` | `#C2691A` | high |
| `risk.3` | `#9C8000` | medium |

### 10.2 The one-colour rule, enforced in the theme

Note a2: *three risk levels only. If colour appears anywhere else it loses its meaning. This is a constraint worth enforcing in tokens, not in design review.*

Implementation, exactly as instructed:

* The Tailwind theme exposes **no chromatic token except `risk.1/2/3`**. Everything else is a neutral. A developer reaching for an accent colour finds that none exists — the constraint is enforced by absence.
* A lint rule bans raw hex and `rgb()` in `components/` and `app/`.
* Only `components/risk/` may reference `risk.*`. Anywhere else is a lint error.

The result: making a "success green" button requires editing the theme, which is a visible, reviewable act rather than an inline convenience.

**Note on `--spec` (`#1B4F9C`).** The wireframe sheet's blue is annotation chrome — callout tags, note numbers, spec strips. It appears nowhere inside a `.viewport`. It is **not a product token** and must not enter the theme. (Verified: every `--spec` reference in `wireframes.html` sits outside the device frame.)

### 10.3 Typography rule

Three families, with a rule the wireframe follows without stating:

| Family | Used for |
|---|---|
| **Suez One** | screen titles only |
| **Assistant** | all prose — names, labels, sentences |
| **IBM Plex Mono** | **machine-readable quantities only** — clock times, dates, day counts, currency, progress fractions (`4 / 8`) |

Every numeric or temporal value in all four plates is mono; no prose ever is. This is what makes "18 יום" and "₪2,400" read as data at a glance. Encoded as a `<Metric>` primitive rather than left to per-component discipline.

### 10.4 Fonts

Suez One, Assistant and IBM Plex Mono, **self-hosted via `next/font`**, subset to Hebrew + Latin. No runtime request to Google Fonts: it is a render-blocking third-party round trip against the 2-second budget (§18), and on portal routes it would place the page load in a third-party log (§6.3).

---

## 11. RTL as the default direction

`<html lang="he" dir="rtl">`. RTL is not a mode — it is the only direction Phase 1 ships (PRD §5 puts other languages out of scope).

* **Logical CSS properties only**: `inset-inline-start`, `border-inline-start`, `padding-inline`, `margin-inline`. A lint rule bans `left`/`right`/`ml-*`/`mr-*`/`pl-*`/`pr-*`.
* This enforces existing practice rather than introducing policy — `wireframes.html` already uses logical properties throughout (`border-inline-start` on risk cards, `inset-inline-start` on callouts).
* Numerals, times and currency stay LTR inside RTL text; the `<Metric>` primitive (§10.3) sets `dir="ltr"` on its own content so `17:00` and `₪2,400` never reorder.
* Icons implying direction (the back arrow, `→` in the wireframe's `.backbar`) mirror with direction.
* All strings live in a translation layer from day one. Not for translation — for keeping copy out of components, so the risk sentences in §8.3 can be composed from reason codes.

---

## 12. Screens and components

Four screens, in the wireframes' own priority order.

### 12.1 Plate 01 — Today (`/today`)

The home screen, and per PRD §8 the proof of the product: *if she does not open it every morning, the product has failed.*

Order on screen is the design argument, and must not be "improved" into a calendar-first layout: **risk first, then today's sessions, then money.** Note a1: *she already remembers today's meeting; the bride who is about to get stuck is the one she doesn't.*

| Block | Source | Notes |
|---|---|---|
| At-risk brides | `v_course_risk`, ordered by level | The only colour on the screen (§10.2). Each row states its reason (§8.3) |
| Today's sessions | `session` where `scheduled_at::date = today` | One-tap reminder → §14 |
| Open payments | `payment` vs `course.agreed_price` | One number, detail behind a tap |

**Money is a summary, not a list** (note a5): weekly worry, not daily — it does not earn space in the first scroll.

Rendered server-side from **one aggregated query** (§18).

### 12.2 Plate 02 — Bride card (`/brides/[id]`)

PRD §8 marks this the central screen; the wireframe says 80% of usage and *"opened before every session."*

* Countdown (`18 יום`) pinned to the name — days, not dates. Note b1: *a date requires arithmetic; days do not.* Its colour is the bride's risk level, consistent with plate 01.
* Progress as **eight discrete segments, not a continuous bar** (note b2) — sessions are the unit she actually thinks in.
* Tabs: sessions / details / payments / messages.
* **The `needs_review_note` carry-forward floats to the top of the next session** (note b3) — the feature that turns record-keeping into a working tool. She opens this card sixty seconds before the meeting; this is what she needs to see.
* Cancelled sessions stay on the timeline, struck through (note b4).
* **One primary action, context-dependent** (note b6): "Mark session done" becomes "Schedule session 7" after marking. At any moment there is exactly one reasonable thing to do — a menu would be a design failure here.

### 12.3 Plate 03 — Proposed schedule (`/courses/[id]/schedule`)

The §7 engine's UI. Inputs (curriculum, wedding date, cadence, **visible editable buffer**), the feasibility warning **with its remedy** (§7.4), the proposed slots with **visible skips** (§7.6), and two equally-weighted actions — "Confirm" and "Edit manually" (note c4).

### 12.4 Plate 04 — Bride portal (`/p/[token]`)

Phase 2, but designed now because its constraints reach back into Phase 1 (§5, §6.2).

*A different product entirely.* 2–5 visits total, ever.

* **No navigation, no menu, no logo** (note d1). She is not "using a system" — she is checking when the meeting is. Every additional element is friction on someone already stressed.
* "When and where" occupies half the screen. No course view, no topic list (note d2 — *those are not hers*).
* Shared materials, a message action, add-to-calendar.
* Visible expiry date (§6.2).
* Separate route group with **no shared layout** with the instructor app — no shared nav, no shared providers, nothing that could import an instructor-side query.

---

## 13. Server data-access layer

**All bride-data reads and writes go through `lib/data/`, server-side. The browser never holds a Supabase client for bride data.**

This is an architectural constraint with a specific cause, not a stylistic preference.

PRD §10.1 requires an access log for **every viewing** of bride data. Reads do not fire database triggers — Postgres has no `AFTER SELECT`. So the log can only be written where reads are issued, and it can only be *complete* if reads are issued in one place. A direct browser-to-Supabase query, which the client library makes trivially easy, would be an unlogged read: invisible to the audit trail that §16 depends on.

Consequences, accepted deliberately ([ADR-0006](./adr/0006-server-only-data-access.md)):

* Realtime subscriptions are unavailable in Phase 1. Nothing in the PRD needs them.
* Every screen is server-rendered or fetched through a Server Action — which is also what §18's latency budget wants.
* The Supabase anon key is never shipped with permission to read bride tables.

Shape:

```
lib/data/
  brides.ts      listBrides, getBrideCard, createBride
  courses.ts     createCourse (snapshot), recomputeSchedule, confirmSchedule
  sessions.ts    markDone, cancel, reschedule
  records.ts     upsertSessionRecord     ← private data; §5
  today.ts       getTodayScreen          ← the single aggregated query; §18
  portal.ts      resolvePortalToken, getPortalView   ← Path 2 ONLY; service role
  audit.ts       logAccess               ← called by every function above
```

`portal.ts` is the only module allowed to construct a service-role client, and the only one importable from `app/p/`. A lint boundary enforces both directions: `app/p/` cannot import instructor data modules, and instructor modules cannot import `portal.ts`.

---

## 14. WhatsApp integration

PRD §4.4: *WhatsApp is the channel, not the system. We do not try to replace it — we connect to it.*

### 14.1 Mechanism

Deep link to `https://wa.me/<phone>?text=<encoded>`, opening WhatsApp with the message pre-composed. The instructor presses send.

**One tap, no intermediate screen** (note a4): *the most common action in the product must be the shallowest.* From the Today screen, "תזכורת" goes straight to a populated WhatsApp thread — no preview dialog, no confirmation step.

Phone numbers are normalised to E.164 (`+9725…`) on write.

### 14.2 Templates

Bodies contain `{{bride_name}}`, `{{date}}`, `{{time}}`, `{{location}}`, `{{instructor_name}}`. Rendering is a pure function in `lib/domain/templates.ts`; unknown variables render empty and are reported by the editor rather than emitting a literal `{{typo}}` into a message to a client.

Phase 1 seeds system templates at signup (§6.1). D2 (instructor-authored templates) is Phase 2; the table already supports it.

### 14.3 The honest limitation

A `wa.me` deep link **cannot confirm delivery, or even that send was pressed.** The user may edit the text or abandon the thread.

Therefore `message_log.status` is **`composed`**, never `sent`, and the UI says "נשלחה תזכורת" only where it means "you opened a reminder", worded so it does not claim more than it knows. This partially under-delivers D4 ("I see what was sent and when") — see §20.2. Closing the gap requires the WhatsApp Business API, which brings template pre-approval, per-message cost, and a Meta business verification the persona is unlikely to complete. [ADR-0007](./adr/0007-wa-me-deep-links.md) records the trade; Phase 3 revisits it.

---

## 15. Offline and PWA

Scoped exactly to PRD §10.3's promise — *view the schedule and add a note* — and no further.

| Capability | Offline behaviour |
|---|---|
| Today screen, bride cards | Served from cache, with a visible "last updated" time |
| Viewing schedules | Cached |
| Adding a note / marking done | Queued in an IndexedDB outbox, replayed on reconnect |
| Everything else | Requires connectivity, and says so |

**Conflict resolution: per-field last-write-wins on `updated_at`.** Chosen because the realistic conflict — one instructor, two devices, or one device replaying a stale queue — is rare and low-stakes. Notes are append-oriented and single-author; CRDTs would be unjustified complexity here. The one guard: an outbox entry older than 7 days is surfaced for confirmation rather than replayed silently, because a week-old queued edit may no longer be what she wants.

Install prompt after the third session (PRD §10.3, PWA to home screen without an app store). App name and icon are neutral (§6.3).

---

## 16. Security, privacy, retention

PRD §10.1 is unambiguous: *the database holds names, phone numbers, wedding dates and personal notes about religious women. A leak is not a malfunction — it is the end of the product and the end of the customers' professional reputations.* Design follows from treating that as the primary requirement rather than a checklist.

### 16.1 Controls

| Control | Design |
|---|---|
| Tenant isolation | RLS, §4, tested |
| Private/public boundary | Physical table separation, §5, tested |
| In transit | TLS, HSTS |
| At rest | Provider-managed encryption + full-disk |
| Access log | `access_log`, written by `lib/data/audit.ts`, §13 |
| App lock | WebAuthn, §6.1 |
| Portal | Hashed tokens, expiry, rate limit, no indexing, §6.2 |
| Backups | Provider PITR **plus a restore drill that is actually performed** — an untested backup is not a backup |
| Dependencies | Lockfile, automated advisories, minimal third-party JS; **zero third-party scripts on portal routes** |

### 16.2 The unanswered question that blocks development

PRD §14 lists it first: *can the product team read the notes? An explicit decision is required before the first line of code.*

**Recommendation: no, by default — and enforced, not promised.**

* Production database access requires a break-glass procedure: a named person, a stated reason, a time limit, and an entry in `access_log` with `actor_kind = 'support'`.
* Support tooling exposes metadata (counts, dates, statuses) and never note bodies.
* The policy is published in plain Hebrew in the product, because §11.4 identifies trust as the binding adoption constraint — *a religious woman will not upload intimate notes about brides to an anonymous startup's cloud.* An unpublished policy buys none of that trust.

This needs a decision from the product owner, not from this document. It is recorded here so it cannot be reached by default.

### 16.3 Client-side note encryption — considered, deferred

PRD §10.1 raises it and names the trade: *sells excellent trust, breaks search — a conscious decision.*

Deferred for Phase 1, because it also breaks server-side rendering of note content (§13), password recovery without data loss, and any future cross-device sync. The honest position: it is the strongest possible answer to §16.2, and if a certification organisation partnership (§11.4) demands it, it becomes a Phase 3 project with its own key-management design — not a flag to be flipped.

### 16.4 Retention, export, erasure

* **Export** (F4): CSV for the accountant, plus a full-account JSON export. User-initiated, no support ticket.
* **Erasure**: soft delete by default; hard delete on request, cascading across the tenant's data. `access_log` retains the record of access, holding identifiers only (§3.11).
* **Retention after completion** is PRD §14's fourth open question. Recommendation: **archive indefinitely, delete never by default.** Completion certificates (G1) may be requested years later, and silent automatic deletion of professional records would be the worse surprise. Bulk deletion is offered as an explicit action.

### 16.5 Legal

Amendment 13 to the Israeli Privacy Protection Law imposes obligations that plausibly apply here (database registration, a security officer, breach notification, DPIA). **This document is not a legal opinion and its author is not qualified to give one.** PRD §10.1 already flags the need for legal review; that review should happen before beta users hold real bride data, not before launch.

---

## 17. Testing strategy

### 17.1 Database (written, executed, passing)

`schema.test.sql` is not aspirational — it runs. It asserts, as an ordinary `authenticated` user:

1. Tenant A sees only tenant A's brides — including when addressing tenant B's row by primary key.
2. `session_record` is isolated; `private_note` never crosses tenants.
3. Both views respect the caller's RLS (the `security_invoker` finding, §4.2).
4. `WITH CHECK` rejects an insert attributed to another tenant.
5. An update against another tenant's row affects zero rows.
6. `access_log` is insertable but not deletable.
7. `portal_session_view` exposes exactly the seven permitted columns.
8. The three private field names appear in exactly one relation in the schema.
9. All five risk tiers rank as §8.1 specifies.

To run, with any Postgres 15+:

```bash
createdb pinkas_test
psql -d pinkas_test -v ON_ERROR_STOP=1 \
  -f docs/schema.bootstrap.sql \   # emulates Supabase's auth.uid() and roles
  -f docs/schema.sql \
  -f docs/schema.test.sql
```

Non-zero exit means the isolation design regressed. This belongs in CI from the first commit.

### 17.2 Domain engines

Vitest, fixture-table driven, against the pure functions in `lib/domain/`:

* **Scheduling** — Tisha B'Av mid-course (the skip plate 03 actually shows); a wedding closer than the buffer; a wedding *inside* the buffer; Hebrew leap years; multi-day Yom Tov; cadence that cannot fit; every session pinned; a blackout colliding with a pinned session.
* **Risk** — each tier at its boundary (exactly 21 days, exactly 7 days, exactly at the deadline), plus a course with zero sessions.
* **Templates** — unknown variable, empty value, RTL punctuation.

Both engines are pure, so these are fast and deterministic — no database, no clock, `today` injected.

### 17.3 Integration and UI

* Portal access: valid token, expired token, revoked token, malformed token, another tenant's token.
* Playwright smoke tests over the four screens in RTL at 375px, including the empty state in §8.5.
* An automated axe pass for §18.2.

---

## 18. Performance and accessibility budgets

### 18.1 Performance

PRD §10.3: the home screen loads in **under 2 seconds on a cellular connection**. It is the screen she opens every morning; if it is slow she stops opening it, and per PRD §8 that is product failure.

* Today is server-rendered from **one aggregated query** (`lib/data/today.ts`) — risk, sessions and payment totals together. Not three round trips.
* Budget: ≤150 KB JS gzipped on the Today route. The screen is mostly text and borders; the wireframe implies almost no client-side interactivity.
* Self-hosted fonts, subset, preloaded (§10.4).
* Portal routes: no analytics, no third-party JS at all (§6.3).

### 18.2 Accessibility

* Contrast: the token set is high-contrast by construction (`ink #101418` on `screen #FFFFFF`). **The three risk colours must be verified against WCAG AA at their actual sizes** — `risk.3 #9C8000` on white is the one to check, since it is used at 11px in `.risk-days`. If it fails, darken the token rather than enlarging the text.
* **Risk is never encoded by colour alone.** The wireframe already pairs every colour with a reason sentence and a day count (§8.3), so the information survives colour-blindness and greyscale. Preserve that pairing.
* Full keyboard operability, visible focus, semantic landmarks, `lang="he"` and `dir="rtl"` on the document.
* Screen-reader labels on icon-only controls, of which the wireframe has few by design.

---

## 19. Forward compatibility (Phases 2–3)

Only what constrains Phase 1 today.

### 19.1 Organisation accounts (P3)

`tenant_id` is present on every table from day one, so introducing an `organization` layer is a data migration (`instructor.organization_id`, policies widened from `= auth.uid()` to a membership test) rather than a schema redesign. Adding the indirection *now* would be speculative complexity for a product whose primary persona is a sole practitioner.

### 19.2 Curriculum library and fork (P3)

`curriculum_snapshot` is versioned (`snapshot_version`), so a future fork mechanism can read courses created under today's shape. PRD §14's risk register warns against the product supplying content — the library is a fork mechanism over user-authored templates, never an official curriculum.

### 19.3 Payments and invoicing (P3)

`payment` already models split payers (F3). Green Invoice / iCount integration adds an `invoice` table and an external id; nothing in Phase 1 blocks it.

### 19.4 Vertical expansion (PRD §11.3)

The strategic option — groom instructors, bar mitzvah teachers, couples counsellors — is the same model: *student · course · deadline · payment*. Phase 1 stays compatible by keeping domain vocabulary at the boundary. The entities are already structurally generic; `bride`/`instructor` are naming choices over a shape that generalises. A rename is a migration, not a rewrite — but it should not be pre-emptively abstracted now, because the concrete naming is worth more to the only users who currently exist.

---

## 20. Where this document pushes back

Four places the design deliberately does not do what was asked, plus the questions that remain open.

### 20.1 The premise is still unvalidated

PRD §15 is explicit that the core assumption — *the central pain is the deadline, not organisation* — has not been tested, and prescribes 8–10 depth interviews before any code.

**That should happen before Phase 1 is built.** This document does not change that; it makes the interviews cheaper by making the consequences concrete. If the interviews say the real pain is billing or content, §7 and §8 are the wrong core and most of this document is wrong with them. The parts that survive regardless are §3–§6 and §16: schema, isolation, and privacy are needed by any version of this product.

### 20.2 D4 is only partially satisfiable

"I see what was sent and when" cannot be delivered by `wa.me` links. Phase 1 shows what was *composed*. Shipping a "sent ✓" indicator that means "we opened WhatsApp" would be a small lie in exactly the place — messages to clients — where the product cannot afford one. §14.3.

### 20.3 Biometric lock is weaker than it sounds

PRD §10.1 lists it among encryption and RLS. It is not that class of control: it gates the UI, not the data, and the session token remains on the device. It is worth building for the stated reason (she hands the phone to her children), but it should not be represented to users as protecting their data from a lost phone. §6.1.

### 20.4 The team-access question blocks the first commit

§16.2. The PRD asks it; this document recommends an answer and a mechanism; someone must actually decide. It is listed here rather than in a backlog because the honest answer changes what gets built — publishing "no one can read your notes" while support tooling can is worse than never claiming it.

### 20.5 Open questions carried forward

| PRD §14 question | Phase-1 default | Where |
|---|---|---|
| Can the product team read notes? | No, break-glass only — **needs owner sign-off** | §16.2 |
| What is the right buffer before the wedding? | 14 days, editable, remembered per instructor | §7.2 |
| Should the bride see topics, or only dates? | Dates only; a change means a new view, never a wider one | §5.3 |
| What happens to data after completion? | Archive indefinitely; explicit bulk delete offered | §16.4 |
| Is there a formal rabbinate reporting requirement? | **Unknown — needs research.** Would add an export format; no schema impact expected | — |

---

## Appendix A — Document map

| File | Role |
|---|---|
| [`PRD.md`](./PRD.md) | Product requirements (Hebrew), v0.1 — the *what* and *why* |
| [`wireframes.html`](./wireframes.html) | 4 annotated screens — open in a browser |
| `SDD.md` | This document — the *how* |
| [`schema.sql`](./schema.sql) | Authoritative schema; becomes migration `0001_init.sql` |
| [`schema.test.sql`](./schema.test.sql) | Isolation and risk-tier verification |
| [`schema.bootstrap.sql`](./schema.bootstrap.sql) | Supabase emulation for local testing |
| [`adr/`](./adr/) | Seven decision records |

## Appendix B — Decision records

| ADR | Decision |
|---|---|
| [0001](./adr/0001-nextjs-supabase.md) | Next.js + Supabase |
| [0002](./adr/0002-rls-as-the-isolation-boundary.md) | Postgres RLS as the isolation boundary |
| [0003](./adr/0003-session-record-separation.md) | `session_record` as a separate table |
| [0004](./adr/0004-curriculum-snapshot.md) | Curriculum snapshot at course creation |
| [0005](./adr/0005-hashed-portal-tokens.md) | Hashed opaque portal tokens |
| [0006](./adr/0006-server-only-data-access.md) | Server-only data access |
| [0007](./adr/0007-wa-me-deep-links.md) | `wa.me` deep links over the Business API |
