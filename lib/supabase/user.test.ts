import { ResponseCookies } from "next/dist/server/web/spec-extension/cookies";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * ADR-0009 mitigation 1, SDD §6.1: the session cookie is `HttpOnly`, `Secure`,
 * `SameSite=Lax`, `Path=/`. Asserted from the SERIALISED `Set-Cookie` header —
 * the failure that matters is the library (or Next's serialiser) dropping a
 * flag, not an author forgetting to type one — so this drives a real
 * `@supabase/ssr` client through a real OTP verification, with only the
 * network stubbed, and reads back what Next would send.
 */

const jar = vi.hoisted(() => ({ headers: new Headers(), cookies: null as unknown }));

vi.mock("next/headers", () => ({
  cookies: async () => jar.cookies,
}));

function b64url(value: object): string {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

const SUB = "11111111-1111-4111-8111-111111111111";
const now = Math.floor(Date.now() / 1000);
const ACCESS_TOKEN = `${b64url({ alg: "HS256", typ: "JWT" })}.${b64url({
  sub: SUB,
  role: "authenticated",
  aud: "authenticated",
  exp: now + 3600,
  iat: now,
})}.signature`;

beforeEach(() => {
  jar.headers = new Headers();
  jar.cookies = new ResponseCookies(jar.headers);
  vi.stubEnv("SUPABASE_URL", "https://abcdefghijklmnop.supabase.co");
  vi.stubEnv("SUPABASE_ANON_KEY", "anon-key-for-test");
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("/auth/v1/verify")) {
        return new Response(
          JSON.stringify({
            access_token: ACCESS_TOKEN,
            refresh_token: "refresh-token",
            token_type: "bearer",
            expires_in: 3600,
            expires_at: now + 3600,
            user: { id: SUB, aud: "authenticated", role: "authenticated", phone: "972501234567" },
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      if (url.includes("/auth/v1/logout")) return new Response(null, { status: 204 });
      return new Response("{}", { status: 404, headers: { "content-type": "application/json" } });
    }),
  );
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

function sessionCookies(): string[] {
  return jar.headers.getSetCookie().filter((c) => c.startsWith("sb-"));
}

function expectFlags(header: string, maxAge: number) {
  const attrs = header.split(";").map((a) => a.trim().toLowerCase());
  expect(attrs, header).toContain(`max-age=${maxAge}`);
  expect(attrs, header).toContain("httponly");
  expect(attrs, header).toContain("secure");
  expect(attrs, header).toContain("samesite=lax");
  expect(attrs, header).toContain("path=/");
  expect(attrs.some((a) => a.startsWith("domain=")), header).toBe(false);
}

describe("session cookie flags, read from Set-Cookie", () => {
  it("are set on sign-in (OTP verified)", async () => {
    const { createUserClient } = await import("./user");
    const client = await createUserClient();
    const { error } = await client.auth.verifyOtp({ phone: "+972501234567", token: "123456", type: "sms" });
    expect(error).toBeNull();
    await vi.waitFor(() => expect(sessionCookies().length).toBeGreaterThan(0));

    // 30 days, not the library's 400 (#60 review)
    for (const header of sessionCookies()) expectFlags(header, 2592000);
  });

  it("are set on the clearing cookie at sign-out too, which stays a removal", async () => {
    const { createUserClient } = await import("./user");
    const client = await createUserClient();
    await client.auth.verifyOtp({ phone: "+972501234567", token: "123456", type: "sms" });
    await vi.waitFor(() => expect(sessionCookies().length).toBeGreaterThan(0));

    jar.headers = new Headers();
    const before = jar.cookies as ResponseCookies;
    jar.cookies = new ResponseCookies(jar.headers);
    // carry the session over so the client has something to clear
    for (const c of before.getAll()) (jar.cookies as ResponseCookies).set(c.name, c.value);
    jar.headers.delete("set-cookie");

    const again = await createUserClient();
    await again.auth.signOut({ scope: "local" });
    await vi.waitFor(() => expect(sessionCookies().length).toBeGreaterThan(0));
    for (const header of sessionCookies()) expectFlags(header, 0);
  });

  it("override whatever options the library hands setAll", async () => {
    const { SESSION_COOKIE_FLAGS } = await import("./user");
    expect(SESSION_COOKIE_FLAGS).toEqual({
      httpOnly: true,
      secure: true,
      sameSite: "lax",
      path: "/",
      maxAge: 30 * 24 * 60 * 60,
    });
    expect(Object.isFrozen(SESSION_COOKIE_FLAGS)).toBe(true);
  });

  it("refuses to build a client without configuration, naming no values", async () => {
    vi.stubEnv("SUPABASE_URL", "");
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "");
    const { createUserClient } = await import("./user");
    await expect(createUserClient()).rejects.toThrow(/SUPABASE_URL/);
  });
});
