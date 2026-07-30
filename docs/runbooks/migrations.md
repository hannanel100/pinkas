# Runbook — applying migrations

How a migration reaches a live Supabase project, who runs it, and why the path
is shaped this way. `infra` owns this mechanism; what is *inside* a migration
is `database`'s surface and is reviewed as such (CLAUDE.md, agents table).

## The decision: a named human applies migrations, not CI

`pnpm exec supabase db push`, run by hand from a linked local checkout of
`main`, by the project owner (currently: hannanel). CI holds no database
credential.

Why manual, when manual application is exactly how environments drift:

* **The credential that applies migrations can rewrite the RLS policies.** In
  this repo the schema *is* the isolation boundary (invariants 1, 2, 5). A CI
  secret that can push schema is not "CI can deploy" — it means anything that
  can read CI secrets or alter CI config can silently remove tenant isolation.
  CI logs and build artefacts are also precisely the places issue #27 forbids
  keys from reaching.
* **Cadence is low and the team is one person.** The drift that manual
  application risks is bounded by making verification a script instead of an
  eye: `scripts/verify-live-schema.sh` fails loudly when the linked project
  differs from `supabase/migrations/`.

Revisit when release cadence makes a forgotten push the larger risk. That
reversal is an ADR, not a quiet workflow edit.

## The rule that orders every schema release

**The app rolls back; the database mostly does not.** A bad deploy is reverted
in a minute; a migration that dropped a column is not. Therefore:

1. **Expand** — schema changes ship *ahead of* the code that needs them, and
   must be backward-compatible with the code currently in production (add
   columns nullable or defaulted, add new tables/views, never repurpose).
2. **Migrate** — deploy the code that uses the new shape.
3. **Contract** — drops and renames ship in a *later* release, once no deployed
   code path touches the old shape.

Never ship a migration and the code that depends on it as one atomic hope.

## Procedure

Prerequisites, once per machine:

```bash
pnpm install                      # brings the pinned Supabase CLI (devDependency)
pnpm exec supabase login          # opens the browser; token lands in your keychain
pnpm exec supabase init           # only if supabase/config.toml does not exist yet
```

Per migration:

1. **Preconditions.** The migration is merged to `main`; CI is green, including
   the `schema.test.sql` suite against the bootstrap harness. Migration files
   live in `supabase/migrations/` and are never edited or deleted once applied
   anywhere. `0001_init.sql` specifically must remain byte-identical to
   `docs/schema.sql`.
2. **Staging first.**
   ```bash
   pnpm exec supabase link --project-ref <staging-ref>   # prompts for db password
   pnpm exec supabase db push                            # lists pending; confirm
   ./scripts/verify-live-schema.sh
   ```
   If the migration touches tables, policies, views or grants, also run the
   live RLS harness (staging only — it seeds and deletes data):
   ```bash
   PINKAS_LIVE_TEST=staging node scripts/test-live-rls.mjs
   ```
3. **Production.**
   ```bash
   pnpm exec supabase link --project-ref <prod-ref>
   pnpm exec supabase db push
   ./scripts/verify-live-schema.sh
   ```
   Never run the seeding harness against production. The read-only anon check
   (`PINKAS_LIVE_TEST=prod-anon-only`) is safe there.
4. **Record.** Comment on the PR or ticket: migration name(s), project ref,
   date, and the tail of the verify output. Applied-by-whom should never be a
   matter of memory.

## Rollback

* **Bad code, good schema** — revert the deploy (Vercel runbook, #7). This is
  the normal case the expand/contract rule exists to preserve.
* **Bad migration, nothing depends on it yet** — write a new forward migration
  that undoes it. Applied migration files are never edited or removed.
* **Destructive mistake** — Supabase PITR (SDD §16.1, backups). Last resort:
  it restores the whole database, losing writes since the restore point. The
  §16.1 restore drill is what makes this a plan rather than a hope.

## Credentials

* `SUPABASE_ACCESS_TOKEN` — created by `supabase login`, held in the
  operator's OS keychain (or exported for one shell session). Never in the
  repo, never in `.env*`, never in Vercel, never in CI.
* **Database passwords** — password manager only; entered interactively at
  `link` time.
* Nothing in this runbook needs the service-role key. If a step seems to,
  the step is wrong.
