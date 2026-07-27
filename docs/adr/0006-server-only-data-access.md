# ADR-0006 — All bride data access goes through the server

**Status:** Accepted · July 2026
**Relates to:** SDD §2.2, §13

## Context

Supabase's client library is designed to be called from the browser: ship the anon key, let RLS enforce isolation, query directly. It is the documented happy path and it removes a whole tier of code.

It is incompatible with a requirement in PRD §10.1: **an access log for every viewing of bride data** ("לוג גישה לכל צפייה בנתוני כלה").

Postgres has no `AFTER SELECT` trigger. Reads cannot be logged by the database. They can only be logged where they are issued — which means a complete log is possible only if reads are issued in one place.

A browser-issued query is an unlogged read. Not a gap in the log; an invisible one, indistinguishable from no access at all.

## Decision

All bride-data reads and writes go through server-side modules in `lib/data/`. **The browser never holds a Supabase client for bride data.**

```
lib/data/
  brides.ts  courses.ts  sessions.ts
  records.ts    ← private data (ADR-0003)
  today.ts      ← the single aggregated Today query
  portal.ts     ← Path 2 only; the only module that may use the service role
  audit.ts      ← logAccess, called by every function above
```

Each read path calls `audit.logAccess` with actor, bride, action and resource. Because there is exactly one way to reach the data, the log is complete by construction rather than by discipline.

Lint boundaries enforce the shape in both directions: `app/p/` (the portal) cannot import instructor data modules, and instructor modules cannot import `portal.ts`.

## Consequences

**Good.**

- The access log is complete, which is what makes SDD §16's guarantees real rather than aspirational.
- The Supabase anon key is never shipped with permission to read bride tables. A key leak is not a data leak.
- One place to add caching, rate limiting, or field-level redaction later.
- Server rendering is what SDD §18's 2-second budget wants anyway, so this costs nothing on the metric that matters.

**Costs, accepted.**

- **No realtime subscriptions in Phase 1.** Realtime requires a browser-held client. Nothing in the PRD needs it — a single instructor on a single device has no one to sync with.
- More code than direct client queries: every read is a function rather than an inline call.
- Optimistic UI needs explicit handling, which the offline outbox (SDD §15) provides anyway.

## Note on defence in depth

This does not replace RLS (ADR-0002). RLS still applies, because server-side clients carry the user's JWT rather than the service role. Two independent mechanisms must both fail before data crosses tenants: the query layer would have to lose its scoping *and* the database policy would have to be missing.

The service role — which bypasses RLS entirely — exists in exactly two places: the portal path (ADR-0005), where the only untrusted input is a token that is hashed before use, and scheduled jobs, which take no user input at all.
