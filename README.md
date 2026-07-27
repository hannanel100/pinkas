# pinkas

A management system for independent bride instructors (מדריכות כלה) — curriculum building, bride files, session tracking, reminders and payment tracking, designed for mobile.

The product is built around a **hard deadline** — the wedding date — rather than around a calendar. That is what separates it from a generic CRM, and it is the organising idea behind most of the design decisions in these documents.

> **Status: design only.** No application code exists yet. The PRD's own next step (§15) is 8–10 depth interviews with working instructors to validate the core premise before development begins.

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

## Before writing application code

Two things are unresolved and both are called out in the design:

1. **Can the product team read instructors' private notes?** The PRD asks for an explicit decision before the first line of code. SDD §16.2 recommends an answer and a mechanism; someone still has to decide.
2. **The core premise is unvalidated** — that the central pain is the deadline rather than organisation. SDD §20.1.
