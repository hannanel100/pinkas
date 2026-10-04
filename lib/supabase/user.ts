import "server-only";

import { createServerClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";
import { cookies } from "next/headers";

/**
 * Path 1 — the instructor's client, carrying HER JWT. SDD §2.3.
 *
 * RLS is active on every request this client makes: `tenant_id = auth.uid()`
 * is decided by Postgres from the JWT in her session cookie, not by anything
 * this codebase passes. That is invariant 1, and it is why this is the only
 * client factory the instructor path has.
 *
 * ── Who may import this ────────────────────────────────────────────────────
 *
 * `lib/data/context.ts`, and nothing else (enforced in `eslint.config.mjs`;
 * type-only imports are allowed). context.ts exports `defineRead` and
 * `defineMutation` — never this factory — so a function that does not write
 * the access log cannot obtain a client at all (#7 design challenge; ADR-0006).
 *
 * ── The session cookie (ADR-0009, mitigation 1) ────────────────────────────
 *
 * The JWT in this cookie, used directly against PostgREST, is the one way past
 * `lib/data/` — an unlogged read of everything `authenticated` is granted. The
 * primary defence is that page script cannot read it. `@supabase/ssr` defaults
 * to `httpOnly: false` and writes whatever options it is handed; Next's
 * `cookies().set()` does not default to `httpOnly` either. So the flags are
 * forced twice — as `cookieOptions`, and again over whatever options the
 * library passes to `setAll` — and `user.test.ts` asserts them from the
 * serialised `Set-Cookie` header, because the failure that matters is the
 * library dropping a flag, not an author forgetting to type one.
 *
 * No Supabase key reaches the browser from here: this module is `server-only`,
 * and sign-in is a Server Action (SDD §6.1), so the browser has no edge to Auth.
 */

/**
 * The flags every session cookie carries. Asserted from `Set-Cookie`.
 *
 * * `sameSite: "lax"`, not `"strict"`: she opens the app from a WhatsApp link,
 *   and a strict cookie is not sent on that first cross-site navigation.
 * * `maxAge` 30 days, not `@supabase/ssr`'s 400: a phone handed to a child
 *   (SDD §6.1) should not stay signed in for over a year. The matching Auth
 *   inactivity timeout is a project setting, `infra`'s (#39) — the cookie
 *   bounds the browser side only.
 */
export const SESSION_COOKIE_MAX_AGE = 30 * 24 * 60 * 60;

export const SESSION_COOKIE_FLAGS = Object.freeze({
  httpOnly: true,
  secure: true,
  sameSite: "lax",
  path: "/",
  maxAge: SESSION_COOKIE_MAX_AGE,
} as const);

/**
 * The client type. No generated `Database` type exists yet, so rows come back
 * untyped and every `lib/data/` module parses them at the boundary into its
 * own types — which it would do anyway, because a row is untrusted input.
 */
export type UserClient = SupabaseClient;

/**
 * Server-side configuration. The non-`NEXT_PUBLIC_` names are preferred: #39
 * drops the prefix from the anon key so it never reaches a client bundle. The
 * prefixed names are read as a fallback only until #39 lands; reading them
 * here, in a `server-only` module, does not ship them anywhere.
 */
function config(): { url: string; anonKey: string } {
  const url = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey =
    process.env.SUPABASE_ANON_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anonKey) {
    // Names only — never values.
    throw new Error(
      "lib/supabase/user: SUPABASE_URL and SUPABASE_ANON_KEY must be set (see .env.example).",
    );
  }
  return { url, anonKey };
}

/**
 * One client per request, bound to the request's cookie store.
 *
 * Writes the session cookie when Auth hands back a session (OTP verified, token
 * refreshed, signed out). In a Server Component render the cookie store is
 * read-only and `set` throws; that case is swallowed, because a refresh during
 * render cannot be persisted from there — it is persisted by the request proxy
 * that refreshes sessions ahead of render (#10). In a Server Action or Route
 * Handler the write succeeds.
 */
export async function createUserClient(): Promise<UserClient> {
  const { url, anonKey } = config();
  const store = await cookies();

  return createServerClient(url, anonKey, {
    cookieOptions: SESSION_COOKIE_FLAGS,
    cookies: {
      getAll() {
        return store.getAll().map(({ name, value }) => ({ name, value }));
      },
      setAll(toSet) {
        try {
          for (const { name, value, options } of toSet) {
            // Spread LAST: the library's options never override the flags —
            // except a removal (`maxAge: 0`, sign-out), which must stay a
            // removal rather than become a 30-day empty cookie.
            const removal = options?.maxAge === 0;
            store.set(name, value, {
              ...options,
              ...SESSION_COOKIE_FLAGS,
              ...(removal ? { maxAge: 0 } : {}),
            });
          }
        } catch {
          // Server Component render — see the function comment.
        }
      },
    },
  });
}
