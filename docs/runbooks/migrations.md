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

## Naming a new migration

```
supabase/migrations/NNNN_lower_snake_name.sql
```

* `NNNN` — four digits, zero-padded. **No gaps, no duplicates**: the numbers
  run 0001, 0002, 0003 … in an unbroken sequence.
* `lower_snake_name` — lowercase letters, digits and underscores only
  (`[a-z0-9_]+`), describing the change: `0003_revoke_default_anon_grants.sql`.
* Nothing else lives in `supabase/migrations/` — no READMEs, no
  subdirectories, no other extensions.

`scripts/test-schema.sh` (`qa`'s) enforces exactly this and applies the files in
numeric order; a name that does not match fails the run rather than being
applied out of order or skipped. This section and that script must say the
same thing. Changing one without the other is a bug.

### Picking the next number

1. Rebase onto `origin/main` first.
2. The next number is the highest `NNNN` in `supabase/migrations/` on `main`,
   plus one.
3. If two open branches pick the same number — routine with parallel work —
   the harness fails with "used more than once" wherever both files meet: on
   the second PR once it is rebased, or, if its checks were green before the
   first one merged, on `main` right after it merges. **The branch that merges
   second renumbers**: rebase, `git mv` its file to the next free number,
   re-run `pnpm test:schema`, push. If the duplicate already reached `main`,
   renumber there in a follow-up PR **before** anyone runs `db push`.

Renumbering is free *only because* of the rule in Procedure step 1: nothing is
applied to staging or production until it is merged to `main`. A migration
file's name is final at merge, never before. If a branch's migration was ever
pushed to a live project before merge, do not rename it — stop and ask, because
the project's migration ledger already records the old version and
`verify-live-schema.sh` will report the mismatch.

### When `supabase migration new` disagrees

`pnpm exec supabase migration new <name>` generates a **14-digit UTC
timestamp** prefix (`20260907065453_add_thing.sql`). The harness rejects it.
Either create the file by hand with the right name, or rename what the CLI
produced:

```bash
git mv supabase/migrations/20260907065453_add_thing.sql \
       supabase/migrations/0003_add_thing.sql
```

The Supabase CLI itself is indifferent: it accepts any all-digit version
prefix, so `db push` orders and records `0003` correctly, and the four-digit
names sort before any timestamp-named file should one ever appear.

### Why four digits and not timestamps

Timestamps have a real argument: they never collide across concurrent
branches. The four-digit form was kept deliberately, not by inertia (#45):

* **A gap is detectable; a missing timestamp is not.** With a dense sequence,
  the harness proves the checkout holds *every* migration. With timestamps, a
  file lost in a merge just isn't there, and the suite reports green on a
  schema no environment has.
* **Collisions are cheap here.** They fail loudly in CI and are fixed by one
  `git mv` on an unmerged branch, because unmerged migrations are never
  applied anywhere (above).
* **`0001_init.sql` cannot be renamed** — it is applied to staging and must
  stay byte-identical to `docs/schema.sql`. Moving to timestamps would mean
  two naming forms coexisting forever.

Revisit if collisions become a weekly cost rather than an occasional one.
Switching is an ADR, and the harness's ordering and gap checks change in the
same PR as this section.

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

* **Bad code, good schema** — Instant Rollback ([vercel.md](./vercel.md#rollback)). This is
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
