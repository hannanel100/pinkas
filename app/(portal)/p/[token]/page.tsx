/**
 * Plate 04 — Bride portal. SDD §12.4, Path 2.
 *
 * Phase 2 by PRD §13, but the route exists now because its constraints reach
 * back into Phase 1 (§5, §6.2) and the boundary is easier to keep than to
 * retrofit: this file sits under a route group with its own root layout, and
 * eslint forbids it from importing any instructor data module (invariant 5).
 *
 * When built: the token is hashed before lookup and never logged (§6.2);
 * "when and where" occupies half the screen with no navigation and no course
 * view (notes d1/d2); the expiry date is shown, because it is a promise rather
 * than a hidden policy.
 *
 * Scaffold placeholder — owned by `frontend` and `backend`.
 */
export default async function PortalPage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  // Not destructured: the token is a credential, and the scaffold should not
  // model holding one. Resolution belongs in lib/data/portal.ts, which hashes
  // it before any lookup.
  await params;
  return <main className="p-6">Portal</main>;
}
