/**
 * Plate 02 — Bride card. SDD §12.2.
 *
 * PRD §8 marks this the central screen; the wireframe says 80% of usage and
 * "opened before every session". Load-bearing when built: the countdown is in
 * days not dates (note b1), progress is eight discrete segments not a bar
 * (note b2), the needs_review_note carry-forward floats to the top of the next
 * session (note b3), and exactly one primary action exists at any moment (b6).
 *
 * Scaffold placeholder — owned by `frontend`.
 */
export default async function BrideCardPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  await params;
  return <main className="p-4">Bride card</main>;
}
