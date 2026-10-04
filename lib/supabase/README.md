# `lib/supabase/` — client factories

**Owning agent:** `backend` · **Design:** SDD §2.3 · ADR-0006, 0009, 0010 · **Reviewed by:** `security`

One module per access path, so the trust levels cannot blur:

| Path | Credential | Module | Trust |
|---|---|---|---|
| 1 — instructor | her JWT, in an `httpOnly` session cookie; RLS active, `tenant_id = auth.uid()` | `user.ts` | authenticated |
| 2 — bride portal | `PORTAL_DATABASE_URL` — the `portal_reader` Postgres login through Supavisor; EXECUTE on the `portal_*` functions only | none here — `lib/data/portal.ts` (#53/#54) | untrusted input |
| 3 — jobs | `pg_cron` in-database; no application client in Phase 1 | — | system |

## `user.ts`

`createUserClient()` builds an `@supabase/ssr` server client bound to the request's cookies. It is
`server-only`, and **only `lib/data/context.ts` may import it** (lint-enforced) — context.ts hands a
client only to the body of a `defineRead`/`defineMutation`, whose wrapper writes the access log.

The session cookie is `HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=2592000` (30 days; `Lax` because `Strict` would drop the cookie when she opens the app from WhatsApp). The matching Auth inactivity timeout is an `infra` project setting (#39). `@supabase/ssr` defaults to
`httpOnly: false` and Next's `cookies().set()` does not default to it either, so the flags are
forced as `cookieOptions` and again over whatever the library passes to `setAll`. `user.test.ts`
drives a real OTP verification and sign-out through the library and asserts the flags from the
serialised `Set-Cookie` header (ADR-0009, mitigation 1).

Configuration is `SUPABASE_URL` / `SUPABASE_ANON_KEY`, falling back to the `NEXT_PUBLIC_` names
until #39 drops the prefix. No Supabase key reaches the browser from here.

## There is no service-role client (invariant 5, ADR-0010)

The portal does not use Supabase's API at all: it has its own Postgres credential, read in
`lib/data/portal.ts` only. `SUPABASE_SERVICE_ROLE_KEY` is in no deployed environment and naming it
under `app/`, `lib/` or `components/` is a lint error; a `lib/supabase/service` module is
import-banned everywhere. `scripts/` is exempt — the staging harness lives there.

`testing/postgrest-client.ts` is test-only — importable from `*.test.ts` alone (lint) — a supabase-js client against a local PostgREST, used by
`lib/data/integration.test.ts` at the factory seam.
