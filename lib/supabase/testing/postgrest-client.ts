/**
 * Test-only: a real supabase-js client against a local PostgREST, carrying a
 * JWT signed with that PostgREST's secret — so `lib/data/` integration tests
 * run their actual queries under the actual RLS policies and grants of
 * `supabase/migrations/`. Substituted for `createUserClient` at the factory
 * seam. Never imported by application code.
 *
 * supabase-js addresses `<url>/rest/v1/...`; a bare PostgREST serves at the
 * root, so the fetch below strips the prefix. `auth.getClaims` is replaced by
 * the claims the token was signed with — GoTrue is not part of this harness,
 * and `context.ts`'s use of those claims is what is under test.
 */

import { createHmac } from "node:crypto";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const BASE = "http://integration.invalid";

function b64url(value: string | Buffer): string {
  return Buffer.from(value).toString("base64url");
}

export function signJwt(secret: string, claims: Record<string, unknown>): string {
  const header = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = b64url(JSON.stringify(claims));
  const sig = createHmac("sha256", secret).update(`${header}.${payload}`).digest("base64url");
  return `${header}.${payload}.${sig}`;
}

export function postgrestClient(
  postgrestUrl: string,
  secret: string,
  claims: Record<string, unknown>,
): SupabaseClient {
  const now = Math.floor(Date.now() / 1000);
  const full = { aud: "authenticated", iat: now, exp: now + 3600, ...claims };
  const jwt = signJwt(secret, full);
  const root = postgrestUrl.replace(/\/$/, "");
  const client = createClient(BASE, jwt, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: {
      headers: { Authorization: `Bearer ${jwt}` },
      fetch: (input, init) => fetch(String(input).replace(`${BASE}/rest/v1`, root), init),
    },
  });
  Object.assign(client.auth, {
    getClaims: async () => ({ data: { claims: full, header: {}, signature: new Uint8Array() }, error: null }),
  });
  return client;
}
