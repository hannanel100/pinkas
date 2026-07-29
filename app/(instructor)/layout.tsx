import type { Metadata, Viewport } from "next";

import { fontVariables } from "@/app/fonts";
import "@/app/globals.css";

/**
 * Root layout for Path 1 — the authenticated instructor app.
 *
 * This is a *root* layout: it renders <html> and <body>. The portal at
 * app/(portal)/ has its own, so the two route groups share no layout, no
 * providers and no navigation. SDD §12.4 requires that separation — it is what
 * makes it structurally impossible for a portal page to inherit something that
 * imports instructor data.
 *
 * `lang="he" dir="rtl"` is not a setting; RTL is the only direction Phase 1
 * ships (§11).
 */

export const metadata: Metadata = {
  // SDD §6.3 — neutral, names no subject matter. Her phone is not always
  // private, and the title is visible in tab lists and screen shares. This is
  // the application's own name rather than product copy; the translation layer
  // (§11) is ticketed to `frontend`.
  title: "פנקס",
  applicationName: "פנקס",
  manifest: "/manifest.webmanifest",
  appleWebApp: { capable: true, title: "פנקס", statusBarStyle: "default" },
};

export const viewport: Viewport = {
  // Designed for 375px first (CLAUDE.md). userScalable stays on: pinch-zoom is
  // an accessibility feature and disabling it fails WCAG.
  //
  // themeColor is deliberately absent. It is a colour value, and the token set
  // is closed (invariant 7) — PWA chrome colour is declared once in
  // public/manifest.webmanifest rather than retyped as raw hex in a TSX file,
  // which the lint rule would rightly reject.
  width: "device-width",
  initialScale: 1,
};

export default function InstructorRootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="he" dir="rtl" className={`${fontVariables} h-full`}>
      <body className="bg-paper text-ink min-h-full antialiased">
        {children}
      </body>
    </html>
  );
}
