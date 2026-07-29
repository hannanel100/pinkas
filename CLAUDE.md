# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**Pinkas** — a mobile-first PWA for independent bride instructors (מדריכות כלה): curriculum building, bride files, session tracking, WhatsApp reminders, payment tracking.

The product is organised around a **hard deadline** — the wedding date — not around a calendar. That single idea explains most of the design decisions; if a change makes the deadline less visible, it is probably wrong.

**Status: design complete, no application code yet.** The repo currently contains documents and an executable schema. The first code commit should scaffold Next.js per SDD §2.4.

## Read these before writing code

| Document | What it covers |
|---|---|
| [`docs/PRD.md`](docs/PRD.md) | Product requirements (Hebrew) — problem, personas, user stories, business model. The *what* and *why*. |
| [`docs/SDD.md`](docs/SDD.md) | Software design — architecture, data model, RLS, scheduling and risk engines, design system, security. The *how*. Section-numbered; ADRs and this file cite it. |
| [`docs/wireframes.html`](docs/wireframes.html) | Four annotated mobile screens. Open in a browser. The annotations are **rules**, not suggestions. |
| [`docs/schema.sql`](docs/schema.sql) | Authoritative schema. Becomes `supabase/migrations/0001_init.sql` unchanged. |
| [`docs/schema.test.sql`](docs/schema.test.sql) | Isolation + risk-tier verification suite. Belongs in CI from the first commit. |
| [`docs/schema.bootstrap.sql`](docs/schema.bootstrap.sql) | Emulates Supabase's `auth.uid()` and roles so the suite runs on plain Postgres. |
| [`docs/adr/`](docs/adr/) | Seven decision records covering the contested choices. |

### The ADRs

| ADR | Decision |
|---|---|
| [0001](docs/adr/0001-nextjs-supabase.md) | Next.js (App Router) + Supabase |
| [0002](docs/adr/0002-rls-as-the-isolation-boundary.md) | Postgres RLS is the isolation boundary — not the ORM |
| [0003](docs/adr/0003-session-record-separation.md) | `session_record` is a separate table, not a field permission |
| [0004](docs/adr/0004-curriculum-snapshot.md) | Snapshot the curriculum when a course is created |
| [0005](docs/adr/0005-hashed-portal-tokens.md) | Hashed opaque portal tokens, not JWT magic links |
| [0006](docs/adr/0006-server-only-data-access.md) | All bride-data access goes through the server |
| [0007](docs/adr/0007-wa-me-deep-links.md) | `wa.me` deep links, not the WhatsApp Business API (Phase 1) |

## Invariants

These are load-bearing. Each one is enforced by a test or a lint rule, not by review discipline — so breaking one should show up as a failure. Do not work around the failure; the constraint is the point.

1. **Tenant isolation lives in Postgres RLS** (`tenant_id = auth.uid()`), never in a `where` clause a developer must remember. The failure mode of forgetting is silent cross-tenant disclosure. ADR-0002, SDD §4.
2. **Private notes are physically separated, not hidden.** `session_record` (covered topics, `private_note`, `needs_review_note`) is unreachable from the bride portal by table structure. Hiding a field in the UI is a future bug. ADR-0003, SDD §5.
3. **`lib/data/` is the only door to the database** for instructor traffic. The browser never holds a Supabase client for bride data — Postgres has no `AFTER SELECT`, so the access log required by PRD §10.1 is only complete if reads happen in one place. ADR-0006, SDD §13.
4. **`lib/domain/` is pure.** `scheduling.ts`, `risk.ts`, `hebrew-calendar.ts`, `templates.ts` do no I/O and import nothing from `lib/data/` or `lib/supabase/` — a lint error. `today` is injected, never read from the clock. This is what makes the fixture tests possible. SDD §2.4, §17.2.
5. **The service-role key exists in `lib/data/portal.ts` only**, reading `portal_session_view` with an explicit `bride_id` filter. `app/p/` cannot import instructor data modules and instructor modules cannot import `portal.ts`. SDD §2.3.
6. **Courses hold a curriculum snapshot.** Editing a template must never rewrite the history of courses already taught from it. `curriculum_id` is provenance only. ADR-0004, SDD §3.5.
7. **Colour carries exactly one meaning: risk.** The theme exposes no chromatic token except `risk.1/2/3`, only `components/risk/` may reference them, and raw hex is banned in `app/` and `components/`. Risk is never encoded by colour alone — always paired with a reason sentence and a day count. SDD §10.2, §18.2.
8. **RTL is the only direction.** `<html lang="he" dir="rtl">`, logical CSS properties only (`inset-inline-start`, `padding-inline`); `left`/`right`/`ml-*`/`pl-*` are lint errors. Machine-readable quantities (times, dates, day counts, currency) render through the `<Metric>` primitive in IBM Plex Mono with `dir="ltr"`. Strings live in a translation layer, so risk sentences can be composed from reason codes. SDD §10.3, §11.
9. **Message status is `composed`, never `sent`.** A `wa.me` deep link cannot confirm delivery. The UI must not claim more than it knows. ADR-0007, SDD §14.3.
10. **The Today screen is one aggregated query**, server-rendered, ≤150 KB JS gzipped, under 2s on cellular. It is the screen she opens every morning; if it is slow the product fails. SDD §18.1.

## Verifying the schema

```bash
createdb pinkas_test
psql -d pinkas_test -v ON_ERROR_STOP=1 \
  -f docs/schema.bootstrap.sql \
  -f docs/schema.sql \
  -f docs/schema.test.sql
```

A non-zero exit means the isolation design has regressed. Run this after any schema change.

## Working conventions

- **The SDD is the source of truth for the *how*; the PRD for the *what*.** When code and document disagree, one of them is a bug — decide which, and fix it rather than letting them drift. `schema.sql` explains itself, so the SDD deliberately does not restate the DDL.
- **A contested decision gets an ADR**, in the existing format: Status, Relates to (SDD section), Context, Decision, and the consequences accepted. Don't bury a reversal of an ADR in a code comment.
- **Product copy is Hebrew.** Code, comments, commit messages and these documents are English.
- **Commits carry no Claude attribution.** No `Co-Authored-By: Claude`, no "Generated with Claude Code", no `Claude-Session` trailer. Enforced by `.claude/hooks/no-claude-attribution.sh`, which rejects the commit before it is made. Prose that happens to mention Claude is fine.
- **Design for 375px first.** Mobile-first literally, not responsively.
- Phase boundaries are real — see PRD §13 and SDD §19. Phase 2/3 features should not be built early, but Phase 1 schema should not block them.

## Decided before code (2026-07-27)

The two blockers the design called out are resolved:

1. **Can the product team read instructors' private notes?** Yes, currently. Support reads must be written to `access_log`, the policy must be published honestly in-product, and this is revisited before public launch. SDD §16.2.
2. **The core premise is validated** — the central pain is the deadline. With a qualification: organisation and sharing materials with the bride matter too, which confirms the material-sharing path and the bride portal belong in Phase 1. SDD §20.1.

## The standing risk

The database holds names, phone numbers, wedding dates and intimate notes about religious women. PRD §10.1 is blunt that a leak is not a bug — it is the end of the product and of the customers' professional reputations. Treat privacy regressions as release blockers, and prefer the design's structural answers (separate tables, RLS, a single read path) over anything that relies on remembering to be careful.
