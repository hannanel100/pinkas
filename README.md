# pinkas

A management system for independent bride instructors (מדריכות כלה) — curriculum building, bride files, session tracking, reminders and payment tracking, designed for mobile.

The product is built around a **hard deadline** — the wedding date — rather than around a calendar. That is what separates it from a generic CRM, and it is the organising idea behind most of the design decisions in these documents.

> **Status: scaffolded.** The Next.js application shell exists — routing, the RTL document, the token set, and the lint rules that enforce the design invariants. The feature layers (`lib/domain/`, `lib/data/`, `lib/supabase/`, `components/`) are deliberately empty and tracked as issues; each of those directories has a README naming its owning agent and design section.

## Running it

```bash
pnpm install
cp .env.example .env.local   # fill in the Supabase values
pnpm dev                     # http://localhost:3000/today
```

| Command | What it does |
|---|---|
| `pnpm check` | lint + typecheck + unit tests — what CI runs |
| `pnpm lint` | **the invariant enforcement**, not a style gate — see below |
| `pnpm typecheck` | TypeScript 7's native compiler |
| `pnpm test` | Vitest, over the pure engines |
| `pnpm test:e2e` | Playwright, RTL at 375px |
| `pnpm test:schema` | the isolation suite against a real Postgres |

### Lint is where the invariants live

CLAUDE.md's invariants are enforced in `eslint.config.mjs`, so breaking one is a build failure rather than something a reviewer has to notice. A failure there is a design regression, and the fix is almost never an `eslint-disable`:

| Invariant | Enforced as |
|---|---|
| 3 — `lib/data/` is the only door to the database | `@supabase/*` importable only inside `lib/supabase/` |
| 4 — `lib/domain/` is pure | no I/O or framework imports; `new Date()` and `Date.now()` banned |
| 5 — service-role key is confined | importable only from `lib/data/portal.ts`; portal and instructor code cannot reach each other |
| 7 — colour means risk, and nothing else | raw hex banned under `app/`+`components/`; `risk-*` tokens only in `components/risk/` |
| 8 — RTL is the only direction | physical utilities (`ml-*`, `pl-*`, `left-*`) and physical CSS properties banned |

Note that ESLint flat config *replaces* a rule when a later block redefines it rather than merging, so two blocks matching the same files silently cancel each other out. `eslint.config.mjs` composes its rules from shared fragments for that reason. When adding one, write a violation and confirm it fails — a rule that passes on clean code proves nothing.

### TypeScript 7, side-by-side with 6

The toolchain runs **TypeScript 7** (the native Go compiler), which ships without the JS compiler API that typescript-eslint and `next build` both need. Per [Microsoft's guidance](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/#running-side-by-side-with-typescript-6.0), the two are installed together:

```jsonc
"@typescript/native": "npm:typescript@^7.0.2",        // provides `tsc`  — the fast compiler
"typescript": "npm:@typescript/typescript6@^6.0.2",   // provides `tsc6` — the API tooling needs
```

So `pnpm typecheck` runs TS 7, while typescript-eslint and `next build` resolve `typescript` to the 6.x API package and work unmodified. TS 7 is a port of 6.0's checker, so the two agree by construction.

Two consequences worth knowing:

- **`experimental.useTypeScriptCli` must stay off.** It makes Next probe for `typescript/bin/tsc`, which does not exist here — the 6.x package names its binary `tsc6` to avoid colliding with TS 7's.
- **typescript-eslint's type-aware rules are unavailable** until it supports TS ≥7.1 ([tracking issue](https://github.com/typescript-eslint/typescript-eslint/issues/10940)). None of the boundary rules above need them.

Revisit this whole arrangement when **TypeScript 7.1** ships the stable programmatic API — at that point the alias should collapse back to a plain `typescript` dependency.

## Documents

| Document | What it covers |
|---|---|
| **[docs/PRD.md](docs/PRD.md)** | Product requirements (Hebrew) — the problem, personas, user stories, business model |
| **[docs/wireframes.html](docs/wireframes.html)** | Four annotated mobile screens. Open in a browser |
| **[docs/SDD.md](docs/SDD.md)** | Software design — architecture, data model, isolation, scheduling engine, security |
| **[docs/adr/](docs/adr/)** | Seven decision records covering the contested choices |

## Schema

`docs/schema.sql` is the authoritative schema and becomes `supabase/migrations/0001_init.sql` unchanged. It has been executed and verified against Postgres 16.

`docs/schema.test.sql` asserts the properties the design depends on: cross-tenant isolation, that private session notes are unreachable from the bride portal, that views respect the caller's row-level security, and that all five risk tiers rank as specified.

```bash
pnpm test:schema          # creates a throwaway database and runs the suite
```

or directly:

```bash
createdb pinkas_test
psql -d pinkas_test -v ON_ERROR_STOP=1 \
  -f docs/schema.bootstrap.sql \
  -f docs/schema.sql \
  -f docs/schema.test.sql
```

A non-zero exit means the isolation design has regressed. It runs in CI on every push, and the script also asserts that `supabase/migrations/0001_init.sql` has not drifted from `docs/schema.sql` — otherwise the thing under test would not be the thing that ships.

## Pre-code decisions — resolved 2026-07-27

The two blockers the design called out have been decided by the product owner:

1. **Can the product team read instructors' private notes?** Yes, currently. Support reads must be logged in `access_log`, the policy must be published honestly in-product, and the decision is to be revisited before public launch. SDD §16.2.
2. **The core premise is validated** — the central pain is the deadline. Qualification: organisation and sharing materials with the bride matter too, which confirms the material-sharing path and bride portal belong in Phase 1. SDD §20.1.
