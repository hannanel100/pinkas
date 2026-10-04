# Runbook — Vercel: project, environments, deploys, rollback (issue #28)

How code reaches production, which credential reaches which deployment, and how
to undo a bad release. `infra` owns this; whether the environment matrix is
*safe* is `security`'s verdict, and nothing in the matrix is final until that
review is recorded on #28.

Supabase-side provisioning (projects, region, OTP, the staging/production
split) is [provisioning.md](./provisioning.md). How a migration reaches a
database is [migrations.md](./migrations.md). Edge controls on the portal path
are [portal-edge.md](./portal-edge.md).

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Function region | `fra1` (Frankfurt), pinned in `vercel.json` | Co-located with Supabase `eu-central-1` (SDD §16.6). Every Today render crosses this link; §18.1's 2s budget assumes it is short. |
| Preview protection | Vercel Authentication, **Standard Protection**, enabled before any variable exists | Previews are public by default; an unguessable URL is not access control, and preview URLs get pasted into PRs. |
| What previews talk to | `pinkas-staging` (fake data only) — never production | Structural answer: a protection failure leaks nothing real. |
| Service-role key in previews | **Absent.** | See "Why previews get no service-role key". |
| Service-role key in production | **Absent until a deployed code path reads it** (`lib/data/portal.ts`, #7); then set last, production scope only, `Sensitive` | A credential with nothing to do is a standing risk with no benefit. |
| Production database before Phase B | **None.** Production scope holds no Supabase variable until `pinkas-prod` exists | Pointing production at staging would put real instructors' data into the fake-data project. |
| Client-bundle proof | `scripts/check-client-bundle.sh` runs as part of every Vercel build (`buildCommand`) | The `NEXT_PUBLIC_` convention is the guard. This check proves the **build output** is clean, against the real key value in the build environment. It is not the whole proof: per-request output is out of its reach (see below). |
| Fork PRs (the repo is public) | Git Fork Protection **on** — confirm from the setting's own text in the dashboard that fork PRs do not build (or do not receive environment variables) without approval | A preview build executes the PR's code with the preview scope's variables. |
| Production promotion | Only git builds of `main` ever serve the production domain — see the hard rule before step 12 | A preview build carries preview-scope values inlined; a local `vercel deploy --prod` carries whatever is on a laptop. |

### What the client-bundle check does not cover

It scans what exists after `next build`: client chunks, prerendered HTML/RSC
and `public/`. It cannot see anything produced **per request**: the HTML and
RSC payloads of dynamic routes (`/p/[token]`, `/today`), Server Action
responses, and Route Handler output. Those are exactly where a server module
holding the service-role client could serialise something it should not.

Covering them needs a runtime test, not a build scan: render `/p/[token]` (and
`/today`) with `SUPABASE_SERVICE_ROLE_KEY` set to a **sentinel** value, fetch
the HTML and the RSC response (`RSC: 1` header), and assert the sentinel is
absent — plus the same for any Server Action or Route Handler under `app/p/`.
Handed to **#7** (which builds `lib/data/portal.ts`) and **#25** (which owns
the integration layer). Until that exists, the build-log line in step 12 is
evidence about artefacts only, and must be described that way.
| Migrations vs code | Schema ships first, in its own PR, applied before dependent code merges | The app rolls back in a minute; a migration does not. [migrations.md](./migrations.md) |

### Why previews get no service-role key

Deployment Protection guards the *URL*. It does nothing about the *build*:
every preview build runs the pull request's code — and every dependency in its
tree — with the preview scope's variables in the environment. Anything that can
open a PR, or land a compromised package in one, can read them at build time
and send them anywhere. No setting closes that; only absence does.

The cost is that a preview cannot exercise the portal read path (`app/p/`).
That is a real cost: the portal is **Phase 1** (SDD §20.1 — material sharing
and the bride portal were confirmed into Phase 1). It is covered instead by
integration tests (#7, #25) against the bootstrap harness, and by staging
exercised from a developer machine, so the trade is a preview that cannot demo
one route against a preview that cannot leak. Even the *staging* key is withheld:
staging holds fake data, but its key bypasses RLS on staging, and the live RLS
harness's results are only meaningful while nobody else can write there.

Revisiting this is a `security`-reviewed change to one cell of the matrix
below, not a dashboard edit. If it is ever reversed, the staging key goes in
with **Preview** scope restricted to a single named branch, never to all
previews.

## Environment matrix

This is the authoritative matrix. Every "absent" is deliberate. Changing any
cell is a `security`-reviewed act, recorded on the ticket that changes it.

"Development" means Vercel's Development scope — what `vercel env pull` writes
to a developer's `.env.local`.

| Variable | Production | Preview | Development (Vercel scope) | Local `.env.local` | CI |
|---|---|---|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | prod project URL — **Phase B only**; absent until `pinkas-prod` exists | staging URL | staging URL | staging URL | absent — CI uses plain Postgres via `schema.bootstrap.sql` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | prod anon key — Phase B only | staging anon key | staging anon key | staging anon key | absent |
| `SUPABASE_SERVICE_ROLE_KEY` | prod key, **Sensitive**, production scope only, **set last** — and only once `lib/data/portal.ts` is deployed and `security` has signed off | **absent** — decision above | **absent** — `vercel env pull` would copy it onto every developer machine | staging key, typed in by the operator by hand, only while working on the portal path | absent |
| `ENABLE_EXPERIMENTAL_COREPACK` = `1` | set | set | set | not needed | not needed |
| `VERCEL_AUTOMATION_BYPASS_SECRET` | n/a | **not created** unless #25 needs to drive a protected preview; if created, it is a credential that unlocks every preview | n/a | never | only if #25 needs it, as a GitHub Actions secret owned by `qa` |
| `SUPABASE_ACCESS_TOKEN` (CLI) | never | never | never | never — operator keychain only | never — CI must not be able to rewrite schema |
| `LIVE_SUPABASE_SERVICE_ROLE_KEY` (input to `scripts/test-live-rls.mjs`) | never | never | never | never in the file — exported in the operator's shell for one run against staging, then unset | never |
| Twilio credentials | held in Supabase Auth settings, not in any app environment | same | same | — | — |

Notes that change how the matrix behaves:

* **Values are snapshotted into each deployment at build time.** Removing a
  variable from a scope does not remove it from deployments already built with
  it. If a secret ever reaches a scope it should not have, removing it is not
  remediation: **rotate it at Supabase** and delete the affected deployments.
* **`NEXT_PUBLIC_` values are inlined into the client bundle at build time.**
  A preview build therefore carries the staging URL in its JavaScript, which
  is one reason a preview is never promoted to production (hard rule, below).
* **#39 changes the anon-key rows**: the key loses its `NEXT_PUBLIC_` prefix
  once #10's server-side OTP path exists. When it does, add the new name to
  `SECRET_VARS` in `scripts/check-client-bundle.sh` so the build proves it.
* **`ENABLE_EXPERIMENTAL_COREPACK=1`** makes Vercel honour `packageManager:
  pnpm@11.1.2` instead of choosing a pnpm major from the lockfile version. Not
  a secret. Unverified until the first build: if install fails, this is the
  first thing to check.

## Deploy flow

* **Production** — every push to `main` builds and, if the build and the
  client-bundle check pass, goes live on the production domain.
* **Preview** — every pull request from a branch of this repository builds a
  protected preview pointed at staging. Fork PRs wait for approval.
* **What a build runs** (`vercel.json`): `pnpm install --frozen-lockfile`, then
  `pnpm run build && pnpm run check:bundle`. A non-zero exit from the bundle
  check fails the deployment; it never goes live. The check prints file names
  and variable names, never values.

### Ordering a release that touches the schema

The app rolls back in a minute; a migration mostly does not. So a schema change
and the code that needs it are **two merges, in this order**:

1. **Expand.** Merge the migration on its own. It is backward-compatible with
   the code currently live (`main` redeploys with no behaviour change). The
   named operator applies it to staging, then production, per
   [migrations.md](./migrations.md), and records it on the ticket.
2. **Migrate.** Only after step 1 is recorded as applied, merge the code that
   uses the new shape. Its preview builds before that point run against a
   staging database that lacks the new shape — expected, and the reason this
   order exists.
3. **Contract.** Drops and renames go in a later release, once no deployed
   code — including the deployment Instant Rollback would restore — touches
   the old shape.

A PR that contains both a migration and code depending on it should be split.

## Rollback

* **Bad code, schema fine** (the normal case): Vercel dashboard, project,
  Deployments, the previous good production deployment, **Instant Rollback**.
  Instant: it reuses the old build, no rebuild. Afterwards Vercel stops
  auto-assigning the production domain to new `main` builds until a deployment
  is promoted again — fix forward on `main`, confirm the new **production git
  build of `main`**, then promote that one (or use Undo Rollback). Never
  promote a preview to get out of a rollback. Record what was rolled back and
  why on the incident ticket.
* **Rolled-back deployments carry their own snapshot of the variables.** If a
  key was rotated after that deployment was built, the restored deployment
  holds the old one. A revoked key fails closed (the portal path errors) — the
  safe direction — but redeploy promptly.
* **Bad migration**: [migrations.md](./migrations.md), "Rollback". Never roll
  the app back past a contract step: the older code may need what was dropped.

## Human checklist

Ordered. **Do not reorder steps 3–6**: protection is proven before any
variable exists, and the proof is captured as output, not memory.

Never paste a key into git, an issue, a PR or a chat. Where a step needs a
secret, it names the dashboard field it goes into.

1. **Plan.** Decide Hobby or Pro. Hobby's terms are non-commercial, and edge
   rate limiting for #40 may need Pro (confirm in the Firewall settings).
   Billing is the owner's call.
2. **Import the project.** Vercel dashboard, Add New, Project, import
   `hannanel100/pinkas`. Framework Next.js (`vercel.json` pins the rest). Root
   directory: repository root. **Add no environment variables on the import
   screen**, even though it offers to.
3. **Protection, before anything else.** Project, Settings, Deployment
   Protection:
   * Vercel Authentication: **on**, **Standard Protection** (all deployments
     except the production domain).
   * Shareable links / "Protection Bypass for Automation": leave **off**.
   * Settings, Git: **Git Fork Protection on**.
   * Settings, General (or Toolbar): **Vercel Toolbar off for preview and
     production** — it loads a third-party script and comment widget on every
     page, portal included (SDD §6.3).
   * Analytics and Speed Insights: **leave disabled** — they record page paths,
     and portal paths are credentials ([portal-edge.md](./portal-edge.md)).
4. **Prove it.** Open any PR (a docs-only one will do) so a preview builds with
   no variables at all. Then, from your machine:

   ```bash
   ./scripts/probe-deployment-protection.sh https://<preview-deployment-url>
   ```

   Paste the full output, including its UTC timestamp, as a comment on #28. No
   secret is in it.
5. **Security review.** Request `security`'s review of the matrix above, as it
   will be applied. Steps 6 onwards wait for it.
6. **Staging values into Preview and Development scopes** — Settings,
   Environment Variables:
   * `NEXT_PUBLIC_SUPABASE_URL` = staging URL (`https://vovvibyjildamppsyoad.supabase.co`), scopes Preview + Development.
   * `NEXT_PUBLIC_SUPABASE_ANON_KEY` = staging anon key, from the staging
     Supabase dashboard (Project Settings, API), scopes Preview + Development.
   * `ENABLE_EXPERIMENTAL_COREPACK` = `1`, all three scopes.
   * **Not** `SUPABASE_SERVICE_ROLE_KEY`, in any scope.
7. **Evidence of order.** Comment on #28 with the creation times of the
   variables from step 6 (Settings, Environment Variables shows them; the
   account Activity log also records them if your plan shows it). They must be
   later than the step 4 timestamp. That pair is the audit trail the
   acceptance criterion asks for.
8. **Check what previews point at.** Settings, Environment Variables, filter
   Preview, then Development: the URL contains the staging ref
   `vovvibyjildamppsyoad` and no other project ref; there are no branch-specific
   overrides. Redeploy the PR preview and re-run step 4's probe — still
   protected with variables present.
9. **Production deploy.** Merge anything to `main` (or Redeploy). Production
   builds with **no** Supabase variables — correct before Phase B; the scaffold
   renders without them. Confirm the build log ends with `client bundle check
   passed`. The production URL (`<project>.vercel.app` or the custom domain)
   is the URL #25 measures §18.1 against; comment it on #25.
10. **Domain** (optional now). If adding a custom domain: the name must be
    neutral — a bride's family may see her portal link, and SDD §6.3 forbids
    identifying words in URLs. The product owner chooses it.
11. **Later, Phase B** (provisioning.md triggers): production URL and anon key
    into Production scope; re-run step 9's check.

> **Hard rule — in force before step 12, and for good after it.** The
> production domain is served **only by git builds of `main`**, deployed
> automatically on push. The only ways a different deployment may take the
> production domain are **Instant Rollback** to an earlier git build of
> `main`, and re-promoting a git build of `main` to end a rollback.
>
> * **Never "Promote to production" a preview deployment.** It was built with
>   preview-scope values and from a branch nobody merged.
> * **Never `vercel deploy --prod`** (or `vercel --prod`) from a local
>   checkout. It builds whatever is on that disk, with whatever is in that
>   shell, and bypasses review.
>
> Check before step 12: project, Deployments, filter Production — every
> deployment listed has a git commit on `main` as its source. Record the check
> on #28. Any exception is investigated before the key goes in.

12. **Last of all.** Preconditions, all recorded on #28: `lib/data/portal.ts`
    (#7) is merged; the runtime sentinel test for per-request output exists
    and is green ("What the client-bundle check does not cover", above);
    the hard rule check above is done; and `security` has signed off. Then:
    `SUPABASE_SERVICE_ROLE_KEY` = **production** service-role key,
    **Production scope only**, type **Sensitive**. Redeploy production (from
    `main`) and confirm the build log shows `ok: value of
    SUPABASE_SERVICE_ROLE_KEY absent from N browser-reachable build files.` —
    the proof that the build saw the real value and did not find it in the
    build output. It says nothing about per-request responses; the sentinel
    test covers those. Comment it on #28.

## Hand back on #28

* step 4 probe output (with timestamp) and step 7 variable creation times
* the preview and production URLs
* the build-log line from step 9 (and step 12, when it happens)
* `security`'s review of the matrix, linked
* one sentence per variable stating where it currently lives
