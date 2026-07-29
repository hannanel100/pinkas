import type { Metadata, Viewport } from "next";

import { fontVariables } from "@/app/fonts";
import "@/app/globals.css";

/**
 * Root layout for Path 2 — the bride portal. A different product entirely
 * (SDD §12.4): 2–5 visits ever, no account, no install.
 *
 * Deliberately shares nothing with app/(instructor)/. No navigation, no menu,
 * no logo (note d1) — she is not "using a system", she is checking when the
 * meeting is, and every additional element is friction on someone already
 * stressed.
 *
 * No analytics and no third-party script of any kind may be added here. The URL
 * contains the access token, so anything that phones home puts a working
 * credential in someone else's log — SDD §6.3. `next.config.ts` sets
 * `Referrer-Policy: no-referrer` and `X-Robots-Tag: noindex` for /p/* at the
 * edge so a new portal route cannot forget them.
 */

export const metadata: Metadata = {
  // SDD §6.3 — neutral title, no identifying words in meta or Open Graph. The
  // bride may be reading this with other people around.
  title: "פנקס",
  robots: {
    index: false,
    follow: false,
    nocache: true,
    googleBot: { index: false, follow: false },
  },
  referrer: "no-referrer",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
};

export default function PortalRootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="he" dir="rtl" className={`${fontVariables} h-full`}>
      <body className="bg-screen text-ink min-h-full antialiased">
        {children}
      </body>
    </html>
  );
}
