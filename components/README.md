# `components/`

**Owning agent:** `frontend` · **Design:** SDD §10 (design system), §11 (RTL), §12 (screens)

Empty by design; the primitives are ticketed.

| Directory | Contents |
|---|---|
| `ui/` | primitives bound to the closed token set (§10) — including `<Metric>` (§10.3) |
| `risk/` | **the only components permitted to emit colour** (§10.2) |

**Invariant 7**, enforced in `eslint.config.mjs`: raw hex and `rgb()`/`hsl()` are errors anywhere
under `app/` or `components/`, and the `risk-*` tokens may be referenced only inside
`components/risk/`. The theme in `app/globals.css` exposes no chromatic token except those three, so
a developer reaching for an accent colour finds that none exists.

Colour alone is never sufficient: §18.2 requires every risk colour to be paired with the reason
sentence (§8.3) and a day count, so the information survives greyscale and colour-blindness.

**Invariant 8**: logical CSS properties only. `ml-*`, `pl-*`, `left-*`, `text-left` and their
physical siblings are lint errors — RTL is the only direction Phase 1 ships.
