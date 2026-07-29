# `lib/supabase/` — client factories

**Owning agent:** `backend` · **Design:** SDD §2.3 · **Reviewed by:** `security`

Empty by design; the factories are ticketed.

One factory per access path, kept in separate modules so the trust levels cannot blur:

| Path | Client | Trust |
|---|---|---|
| 1 — instructor | user's JWT; RLS active, `tenant_id = auth.uid()` | authenticated |
| 2 — bride portal | service role, `portal_session_view` only, explicit `bride_id` | untrusted input |
| 3 — jobs | `pg_cron` in-database; no application client needed in Phase 1 | system |

**Invariant 5.** The service-role client bypasses RLS entirely — it is the one place tenant
isolation is not enforced by the database. `eslint.config.mjs` therefore confines its import to
`lib/data/portal.ts` alone. It must never sit in a code path that accepts arbitrary user input; the
only untrusted input it ever sees is a portal token, hashed before use.

Every module here imports `server-only`, which turns invariant 3 into a build error rather than a
convention.
