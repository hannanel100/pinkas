import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  poweredByHeader: false,

  /*
   * No `experimental.useTypeScriptCli` here, deliberately.
   *
   * That flag exists for projects where `typescript` is TS 7, which ships no JS
   * compiler API. In this repo `typescript` is aliased to the TS 6 API package
   * (see README), so `next build` finds `typescript/lib/typescript.js` and type
   * checks the normal way. Turning the flag on actually *breaks* the build:
   * Next then probes for `typescript/bin/tsc`, and the 6.x package names its
   * binary `tsc6` to avoid colliding with TS 7's.
   *
   * TS 7 still does the real typecheck — `pnpm run typecheck` runs its native
   * `tsc`, and CI runs that as its own step. TS 7 is a port of 6.0's checker,
   * so the two agree by construction.
   */
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "X-Frame-Options", value: "DENY" },
          {
            key: "Strict-Transport-Security",
            value: "max-age=63072000; includeSubDomains; preload",
          },
        ],
      },
      {
        // SDD §6.2/§6.3 — discretion is functional. The portal URL *is* the
        // credential, so it must never reach a referrer header or a search
        // index. Set at the edge rather than in per-page metadata so a new
        // portal route cannot forget it.
        source: "/p/:path*",
        headers: [
          { key: "Referrer-Policy", value: "no-referrer" },
          { key: "X-Robots-Tag", value: "noindex, nofollow, noarchive" },
          { key: "Cache-Control", value: "no-store, max-age=0" },
        ],
      },
    ];
  },
};

export default nextConfig;
