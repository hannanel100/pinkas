# ADR-0002 — Postgres RLS as the isolation boundary

**Status:** Accepted · July 2026
**Relates to:** SDD §4, §13 · verified by `schema.test.sql`

## Context

Every table holds data belonging to exactly one instructor. Cross-tenant disclosure is the failure PRD §10.1 describes as "the end of the product and the end of the customers' professional reputations."

The conventional approach is to scope every query in application code — a `where tenant_id = ?` that a developer must remember. PRD §7.1 rejects it explicitly, and the reasoning is sound: **the failure mode of forgetting is silent disclosure of everything.** A missing filter returns other tenants' rows and looks like a working feature.

## Decision

Tenant isolation is enforced by Postgres Row Level Security. Every tenant-owned table gets:

```sql
create policy <table>_tenant on <table>
  for all to authenticated
  using      (tenant_id = auth.uid())
  with check (tenant_id = auth.uid());
```

Both clauses are required. `USING` governs reads and which rows may be updated; `WITH CHECK` prevents writing a row attributed to another tenant. The test suite asserts that an insert under a foreign `tenant_id` is rejected.

Application-level scoping in `lib/data/` is retained as a second layer. Both must fail before data leaks.

Two derived rules:

1. **Every view must declare `with (security_invoker = on)`.** A view otherwise runs with its owner's privileges and bypasses the caller's RLS entirely. This was verified rather than assumed — see below.
2. `access_log` gets `INSERT` and `SELECT` policies only, so an instructor cannot delete her own audit trail.

## The security_invoker finding

Running the same view definition both ways against the test fixture, queried as tenant A:

| Definition | Rows returned |
|---|---|
| `with (security_invoker = on)` | 13 — tenant A only ✅ |
| default | **14 — tenant A plus one row of tenant B** ❌ |

RLS on the base tables did not save the default view. One leaked row is a total failure of the property this ADR exists to guarantee. `schema.test.sql` asserts the flag remains set on both views, so removing it breaks the build.

## Consequences

**Good.** Isolation fails closed: a query missing its predicate returns nothing, which is a visible bug, not a silent leak. The guarantee holds for any client, including a future admin script or a psql session, because it lives in the database rather than in one codebase's conventions.

**Costs.** Policies must be written for every new table — omitting one leaves it fully readable, so table creation and policy creation belong in the same migration. Debugging "why is this row missing" requires remembering RLS is on. The service role bypasses RLS entirely, which is precisely why SDD §13 confines it to two code paths.

## Alternatives rejected

**ORM-level scoping.** Rejected by the PRD, and correctly: it relies on developer memory at every call site and fails open.

**A database per tenant.** Perfect isolation, but thousands of databases for a product whose whole economic argument (§11.3) is low infrastructure cost, plus a migration story that gets worse with every customer.
