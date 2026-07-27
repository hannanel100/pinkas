# pinkas

A management system for independent bride instructors (מדריכות כלה) — curriculum building, bride files, session tracking, reminders and payment tracking, designed for mobile.

The product is built around a **hard deadline** — the wedding date — rather than around a calendar. That is what separates it from a generic CRM, and it is the organising idea behind most of the design decisions in these documents.

> **Status: design complete, validated.** No application code exists yet, but the core premise has been validated and the pre-code decisions are made (see below) — development can begin.

## Documents

| Document | What it covers |
|---|---|
| **[docs/PRD.md](docs/PRD.md)** | Product requirements (Hebrew) — the problem, personas, user stories, business model |
| **[docs/wireframes.html](docs/wireframes.html)** | Four annotated mobile screens. Open in a browser |
| **[docs/SDD.md](docs/SDD.md)** | Software design — architecture, data model, isolation, scheduling engine, security |
| **[docs/adr/](docs/adr/)** | Seven decision records covering the contested choices |

## Schema

`docs/schema.sql` is the authoritative schema and becomes `supabase/migrations/0001_init.sql` unchanged. It has been executed and verified against Postgres 16.

`docs/schema.test.sql` asserts the properties the design depends on: cross-tenant isolation, that private session notes are unreachable from the bride portal, that views respect the caller's row-level security, and that all five risk tiers rank as specified.

```bash
createdb pinkas_test
psql -d pinkas_test -v ON_ERROR_STOP=1 \
  -f docs/schema.bootstrap.sql \
  -f docs/schema.sql \
  -f docs/schema.test.sql
```

A non-zero exit means the isolation design has regressed. This belongs in CI from the first commit.

## Pre-code decisions — resolved 2026-07-27

The two blockers the design called out have been decided by the product owner:

1. **Can the product team read instructors' private notes?** Yes, currently. Support reads must be logged in `access_log`, the policy must be published honestly in-product, and the decision is to be revisited before public launch. SDD §16.2.
2. **The core premise is validated** — the central pain is the deadline. Qualification: organisation and sharing materials with the bride matter too, which confirms the material-sharing path and bride portal belong in Phase 1. SDD §20.1.
