# ADR-0001 — Next.js + Supabase

**Status:** Accepted · July 2026
**Relates to:** SDD §2

## Context

Pinkas is a mobile-first PWA for independent bride instructors. The constraints that actually drive the choice come from the PRD, not from technical preference:

- **Row Level Security is a stated hard requirement** — PRD §7.1 asks for tenant isolation "at the DB level, **not** at the ORM level".
- **The team must stay lean.** PRD §11.3 is candid that even at high market penetration this is a business of a few million shekels a year, not a growth company: "lean team, no fundraising, early profitability, low infrastructure costs."
- **Mobile-first, installable, under 2s on cellular** — PRD §10.3.
- Hebrew/RTL only, single region, modest data volumes (10–20 brides per instructor; 50+ for the professional persona).

## Decision

Next.js (App Router) on Vercel, with Supabase for Postgres, Auth and Storage.

- Server rendering serves the latency budget without a separate API tier to operate.
- Supabase gives managed Postgres where RLS is a first-class, documented primitive, plus phone OTP auth and private file storage — three things that would otherwise be three integrations.
- `pg_cron` covers the only scheduled work in scope.

## Consequences

**Good.** No API tier and no auth service to run. RLS is available exactly as the PRD requires. Infrastructure cost at this scale is near zero, which matters given §11.3. One language across client, server and domain logic, so the scheduling and risk engines are shared rather than reimplemented.

**Costs, accepted.** Vendor concentration: Supabase holds the database, auth and files. Mitigated by the fact that it is ordinary Postgres — `schema.sql` runs on any Postgres 15+, which the verification suite proves on every run. Migrating away would mean replacing Auth and Storage, not the data.

**Data residency is not resolved by this ADR.** Given PRD §11.4's finding that trust is the binding adoption constraint, region selection and the exact hosting story need a deliberate answer before beta users hold real data. Flagged in SDD §16.5 alongside the legal review.

## Alternatives rejected

**Self-hosted Postgres on Israeli infrastructure.** The strongest answer to the trust problem in §11.4, and genuinely tempting for that reason alone. Rejected for Phase 1 because it puts backups, patching, failover and connection pooling on a team that §11.3 says must be tiny. Revisit if a certification-organisation partnership demands local hosting — the schema is portable by design, so this stays open.

**Firebase / Firestore.** No SQL, therefore no RLS in the sense the PRD requires, and the scheduling queries in SDD §8 are relational. Rejected.

**Rails or Django with a separate SPA.** More operational surface and two languages for one developer, with no compensating benefit at this scale.
