# ADR-0010 — The portal gets its own database login; the service-role key leaves every deployed environment

**Status:** Accepted · October 2026 — settled in the #53 design challenge (2026-10-04, [verdict](https://github.com/hannanel100/pinkas/issues/53#issuecomment-5978335606)); to be implemented by migrations 0008 and 0009 and an `infra` sub-ticket. **Nothing below is true of the deployment until 0008 lands**, and the support half not until 0009.
**Relates to:** SDD §2.3, §6.2, §13, §16.2 · amends [ADR-0005](./0005-hashed-portal-tokens.md) (how the portal reads) and [ADR-0006](./0006-server-only-data-access.md) (where the service role lives, and where the log is written) · extends [ADR-0009](./0009-session-record-column-revoke.md) · companion to [ADR-0011](./0011-portal-link-in-the-fragment.md)

## Context

Invariant 5 said the service-role key exists in `lib/data/portal.ts` only. That was a lint rule inside the codebase and nothing at all inside the database. On a live Supabase project `service_role` holds full default privileges on every table in `public` and has `BYPASSRLS`. Three security reviews in a row — #37 (PR #50), #35 (PR #49), #31/#34 (PR #51) — found the same root cause: a leaked portal credential was a leaked *everything* credential. It could read every tenant's brides, phone numbers, wedding dates and payments in one query, and the only thing standing between the portal's single lookup and all of that was an equality predicate a developer had to remember to write. 0007's own header says so: *"A lookup that forgets the predicate returns every tenant's resolvable brides. Nothing in the database prevents that."*

The same ticket carried a second, related failure. SDD §16.2 requires every support read of bride data to land in `access_log` as `actor_kind = 'support'`. The mechanism it described depended on an `impersonated_by` JWT claim that nothing minted, whose name and location no document pinned. A session minted with the service key — dashboard impersonation, or `generateLink` — was logged as the instructor's own read. `today_screen` (0004) refused impersonated JWTs while `read_session_records` (0006) logged them as support, so the two functions disagreed. And `authenticated` could `insert into access_log` with any `actor_kind`, including a forged `'support'` row.

The ticket posed two options for containment: revoke `service_role`'s table privileges, or create a `portal_reader` role selected by the JWT `role` claim. The exchange rejected both (below). **The argument that decided it is that the service-role key is not only a database credential.** It is also the GoTrue admin credential. No revoke inside Postgres touches that half of it.

## Decision

### 1. The portal has its own Postgres login, and it can do almost nothing

* **`portal_reader`** is a `LOGIN`, `NOBYPASSRLS`, `NOINHERIT` role. The migration creates it `NOLOGIN`. The password and `LOGIN` are set out of band by the operator, so no credential is ever in git.
  * Role limits: `connection limit 20`, `statement_timeout 2s`.
* **`lib/data/portal.ts` connects over the Postgres wire protocol**, through Supavisor in transaction mode: `portal_reader.<ref>` on port 6543, `prepare: false`, TLS, `max: 1` per lambda, `idle_timeout` 20 s, `connect_timeout` 5 s. The credential is **`PORTAL_DATABASE_URL`**. It is not a Supabase API key and goes nowhere near PostgREST.
* **`portal_reader` holds no table privileges at all.** It has `EXECUTE` on three `SECURITY DEFINER` functions and nothing else:
  * `portal_resolve_token(p_token_hash bytea, p_request_id uuid)`
  * `portal_sessions(p_token_hash bytea, p_request_id uuid)`
  * `portal_rate_limit_hit(...)`
* **The functions are owned by `portal_owner`**, a `NOLOGIN`, `NOBYPASSRLS` role — the 0006 pattern, never `postgres`. `portal_owner` holds column grants on exactly what the portal views read, plus SELECT-only policies `to portal_owner`. `portal_rate_limit_prune()` stays with `pg_cron`, which runs as `postgres`.
* **New tables grant it nothing, by construction.** Supabase's default privileges name only `anon`, `authenticated` and `service_role`, and 0005 already removed `PUBLIC` `EXECUTE`. A test creates a table and a function after all migrations and probes both `portal_reader` and `portal_owner`.

### 2. Fixed predicate, and logging inside the function

The #37 review asked whether forgetting the filter could be made impossible rather than only tested for. It can.

* **Each lookup function takes the token hash and nothing else that selects rows.** A NULL hash, or one that is not 32 bytes, is rejected. There is no `bride_id` parameter, so a caller cannot enumerate brides by id. The predicate `portal_token_hash = $1` is written once, inside the function, and the caller cannot widen it.
* **The results come from the unchanged portal views.** `portal_bride_view` and `portal_session_view` lose every direct grant; the functions are their only reader. §5.2's column-list assertion on `portal_session_view` keeps its meaning.
* **Portal logging is complete by construction.** The two lookup functions are `VOLATILE`. Each writes `('bride_portal', bride_id)` to `access_log` in the same statement as the read, keyed on the resolved row, so a failed lookup writes nothing. The actor is a constant inside the function, not a parameter.
  * `portal_owner` gets `INSERT` on `access_log`, with a policy that allows only `actor_kind = 'bride_portal'`. 0001's CHECK already allows that value.
  * The portal route handler therefore does **not** call `logAccess`. ADR-0011's exchange and render rely on the functions' own rows.

### 3. The service-role key leaves every deployed environment

* `SUPABASE_SERVICE_ROLE_KEY` is in **no Vercel scope**: not production, not preview, not development. The production key lives in the operator's keychain only. The staging key is used by the staging harness only.
* **All `service_role` grants in `public`** — 0007's included — and its default privileges there are revoked.
* Inside the codebase, `SUPABASE_SERVICE_ROLE_KEY` anywhere under `app/`, `lib/` or `components/` is a lint error. `scripts/` is exempt, because the staging harness lives there.
* What keeps working without it: `pg_cron` (runs as `postgres`), the dashboard editors (`postgres`), GoTrue admin (`supabase_auth_admin`), and Storage.

### 4. Support attribution: a hook-minted claim, with the fallback named in advance

* **The claim** is top-level `impersonated_by` (the engineer's uuid) plus `support_grant_id`.
* **It is minted by a Supabase Custom Access Token Hook,** `public.custom_access_token_hook`, executable only by `supabase_auth_admin`. The hook reads a **`support_grant`** table (engineer, tenant, reason, expiry, bound session id). Only `postgres` can insert into that table.
* **Procedure.** The operator inserts a grant, then runs `generateLink` for the tenant. The hook binds the grant to the new session id and stamps both claims on that session's token and on every refresh.
* **The hook refuses `magiclink` and `password` issuance that has no grant.** Instructors never sign in those ways (they use phone OTP, SDD §6.1). This is what makes the tooling a control rather than a convention: the service key can still call `generateLink`, but the token it produces is refused unless a grant exists.
* **`today_screen` and `read_session_records` behave the same way:** both log `('support', engineer)`. `today_screen` changes from refusing to logging.
* **The hook is unverified.** It has to be spiked on staging after 0008. The open points are the hook's `authentication_method` values, whether `session_id` is stable across refresh, and whether email-OTP fallback shares a method value with the flow we refuse. **If the hook cannot do this, the fallback is already decided:**
  * `impersonated_by` becomes a reserved claim, and **both** functions refuse it (`42501`).
  * Support reads go only through the dashboard SQL editor, after the operator calls the `postgres`-only `support_log_access(...)`, with pgaudit `read` enabled on role `postgres`.

### 5. Log integrity

* **`authenticated` loses `INSERT` on `access_log`.** The log is written only by functions. Instructor-path reads that `lib/data/` logs go through **`log_access(bride_ids uuid[], action, resource, request_id uuid)`**, a `SECURITY DEFINER` function that takes the actor from the JWT claims, never from a parameter. A forged `'support'` row from an instructor session is refused.
* **`Prefer: tx=rollback` must not apply.** If PostgREST honoured it, a caller could receive the rows of `read_session_records` while the log row rolled back. The staging harness calls the reader with that header and passes only if the preference is not applied and exactly one log row exists.

### 6. Sequencing and the merge gate

| Step | Contents |
|---|---|
| **0008** containment (`database`) | the roles, the three functions, the `service_role` revoke. In the same PR: the `scripts/test-live-rls.mjs` rewrite (each tenant seeds through its own JWT; the service key is used only for `auth.admin.createUser`/`deleteUser`), `verify-live-schema.sh` step 4 asserting containment on the live project, and the #37 assertion "service_role CAN read bride.phone" flipped |
| **0009** (`database`) | `log_access`, the `INSERT` revoke, the `today_screen` change, and the support claim — the hook or the fallback. The instructor-path half lands either way |
| **Composite tenant FKs** | moved out of #53 to their own ticket |

**Merge gate for 0008** (the `infra` sub-ticket, step 1): a real login and a real function call as `portal_reader` through Supavisor, on staging. 0008 does not merge until that succeeds or the fallback below is in place.

## Alternatives rejected

**Revoke `service_role`'s tenant-table privileges, and keep the service key as the portal's credential.** This was the ticket's first option and the obvious move. It stops the one-query dump. It does not contain a leaked key, because the service key is also the GoTrue admin credential. With `auth.admin.generateLink` or `updateUserById`, a holder signs in as any instructor and reads that tenant under RLS, including note bodies through `read_session_records`, and every one of those reads is logged as hers. The revoke is adopted as part of the decision, but as a revoke it contains nothing on its own.

**A `portal_reader` role selected by the JWT `role` claim.** This was the ticket's second option. PostgREST would `SET ROLE` to the claim, after `grant portal_reader to authenticator`. But whatever signs that JWT — the legacy HS256 secret or an imported asymmetric key — can equally sign `role: service_role` with any `sub`. Vercel would hold a **stronger** secret than it holds today. Rejected.

**PostgREST plus the anon key, calling the definer functions.** This was the strongest alternative raised in the exchange, because it needs no second credential type, no Supavisor and no driver. It was rejected for two reasons:

* **ADR-0011's cookie carries the token hash in clear.** The cookie is MAC'd, so it cannot be forged, but its contents are readable by anyone who sees it, for example in a header log. If the hash-keyed functions were callable with the public anon key, that hash would be a capability on its own, valid for the life of the token (months), with none of the cookie's 30-minute expiry. The dedicated credential is what stops a hash from being enough: calling a portal function needs the hash *and* `PORTAL_DATABASE_URL`.
* **It would move the portal's database surface outside the Vercel Firewall.** `https://<ref>.supabase.co/rest/v1/rpc/portal_sessions` is reachable directly, without the edge rate limits of `docs/runbooks/portal-edge.md` §1. The only limiter left would be the DB counter, which is a backstop and not designed to be the primary control.

**A GUC-gated policy on `bride`; an Edge Function holding the service key; a dedicated support Postgres role.** These were considered in the owner's approach and not pursued. The first is a `where` clause by another name (ADR-0002). The second moves the key without containing it. The third gives support a standing login whose reads are logged only if the login chooses to log them.

## Consequences accepted

**A second credential type.** The portal now holds a Postgres connection string, not a Supabase key. It needs its own driver in `portal.ts`, its own rotation (a password change on `portal_reader`, out of band), its own row in the environment matrix, and its own leak response. That is more to operate. It is accepted because the credential it replaces could do everything. The new one can call three functions, and two of those need a token hash to return anything.

**Supavisor may not accept a custom login role.** This is unverified, and it is the reason for the merge gate. If it fails, the portal connects directly to Postgres instead. Supabase's direct connection is IPv6, and Vercel serverless functions cannot open outbound IPv6. **The accepted cost is the paid IPv4 add-on.** That is decided now, so a failed spike does not reopen the design. Latency from `fra1` over a cold wire-protocol connection, compared with PostgREST, is also unmeasured. The portal is not on the §18.1 budget, but it should be measured.

**The hash is now the functions' lookup key.** ADR-0005's "a database disclosure yields hashes, not access" still holds against the web front door: `/p/session` takes the token, never the hash (ADR-0011). It does not hold against someone who has both a dump and `PORTAL_DATABASE_URL`. Such a person already holds the data the portal would show, so they gain nothing. But the claim is narrower than before, and it is stated here so nobody repeats the old wording.

**Residual support risk, stated plainly.** The SDD, and the published privacy policy, must not describe support attribution as stronger than this:

* **The dashboard SQL editor, and any `postgres` connection, reads without a log row** unless the operator calls `support_log_access(...)` first. That call is a procedure, not a control. pgaudit `read` on `postgres` is what makes skipping it visible after the fact.
* **A holder of the service key can still impersonate an instructor.** On the hook path, `magiclink`/`password` issuance without a grant is refused, but the holder can change the instructor's phone with `updateUserById` and sign in by OTP, the method the hook must allow. Those reads are logged as hers. On the fallback path, `generateLink` is not blocked at all, and such reads are logged as the instructor's in the same way.
* **The hook is configured in the dashboard,** so anyone with dashboard access can switch it off. That is the same circle of people as the SQL editor.

What changes is who can do this. Before this decision, every deployed environment that ran the portal held the key. After it, only the operator's keychain does. Against a leak of anything deployed, support attribution is now honest. Against the operator, it remains a procedure backed by an audit log, and is described as one.

**The staging harness is rewritten.** `scripts/test-live-rls.mjs` currently seeds through the service key. In the 0008 PR it seeds each tenant through that tenant's own JWT, and uses the service key only for `auth.admin.createUser`/`deleteUser`. The rewrite makes the harness slower and more code. It also means the harness exercises the same grants the product uses, which the old harness did not.

**Invariant 5 changes its wording, and from 0008 the database enforces it.** CLAUDE.md invariant 5 now names `PORTAL_DATABASE_URL`, the `portal_*` functions, and two lint clauses. The old text, "the service-role key exists in `lib/data/portal.ts` only, reading `portal_session_view` with an explicit `bride_id` filter", describes the design this ADR replaces. Until 0008 lands, the old mechanism is what is deployed.

**Not settled by this exchange: the portal's Storage reads.** SDD §2.2 and §3.7 have the portal reaching shared materials (story E3) in Storage, and signed URLs have so far been minted with the service key. With the key in no deployed environment, `portal.ts` has no credential that can mint them. The exchange did not address this. It needs a design before E3's portal half is built, by `backend` and `database` with a `security` review. The options include a narrowly scoped Storage credential, a server-side stream, or a definer function that returns only object paths, which a separate signer turns into URLs. It is recorded here so the answer cannot be "put the service key back for Storage" by default.
