# Runbook — provisioning Supabase (issue #27)

The decisions, the environment matrix, and the ordered human checklist for
standing up the live projects. Written so the human steps are short, ordered,
and hard to get wrong. Progress is tracked on issue #27, not here.

## Decisions

| Decision | Choice | Reasoned where |
|---|---|---|
| Region | `eu-central-1` (Frankfurt), both projects | SDD §16.6 — signed off by the product owner 2026-07-30 |
| One project or two | Two: `pinkas-prod` and `pinkas-staging`; staging stood up first, production deferred to Phase B | below |
| Who applies migrations | A named human via `pnpm exec supabase db push`; CI holds no db credential | [migrations.md](./migrations.md) |
| OTP provider | Twilio Verify through Supabase phone auth | below |

## Why two projects

A Vercel preview deployment is publicly reachable by default, and preview URLs
get pasted into pull requests. A production service-role key reachable from a
preview build is a full cross-tenant leak (invariant 5, PRD §10.1). Rather
than relying on deployment protection alone, previews and local dev point at
`pinkas-staging`, which holds **fake data only** — then a protection failure
leaks nothing, structurally.

* The production service-role key never enters any scope except the production
  server runtime.
* Staging is also the only legitimate target for the live RLS harness
  (`scripts/test-live-rls.mjs`), which seeds and wipes data.
* **No real bride data in staging, ever.** Not "anonymised" exports either —
  the point of the second project is that nothing in it is worth stealing.
* Same region for both (SDD §16.6): behavioural parity, and the privacy
  policy residency statement stays one sentence.

## Order of operations: protection before secrets

Staging values may enter Vercel preview/development scopes at any time.
The **production** service-role key enters the Vercel production scope **last**,
and only after:

1. deployment protection from #7 is enabled and verified, and
2. `security` has reviewed the matrix below as applied.

## Environment matrix

Every "absent" is deliberate. Changing any cell is a `security`-reviewed act.

| Variable | Vercel production | Vercel preview | Local dev (`.env.local`) | CI |
|---|---|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | prod project | staging project | staging project | absent — CI runs plain Postgres via `schema.bootstrap.sql` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | prod anon key | staging anon key | staging anon key | absent |
| `SUPABASE_SERVICE_ROLE_KEY` | **prod key, production scope only, set last** | staging key only — never the prod key | staging key | absent, deliberately |
| `SUPABASE_ACCESS_TOKEN` (CLI) | never | never | operator keychain only, not in the file | absent — CI must not be able to rewrite schema |
| Twilio credentials | held in Supabase Auth settings, not in our env | same | — | — |

Vercel-side wiring (scopes, deployment protection, domains) is ticket #7;
this matrix is the contract it implements.

## OTP provider

**Decision (signed off by the product owner 2026-07-30): Twilio Verify**, wired through Supabase Auth native phone
provider support.

* Supabase-native integration — no custom SMS hook to write or operate.
* Delivers to Israeli numbers (+972); Israel permits alphanumeric sender IDs
  without pre-registration, so the SMS can arrive from a named sender.
* Verify manages code lifecycle and per-number verification limits (default:
  5 check attempts per code) instead of us storing codes.

Fallbacks, both also Supabase-supported, if Twilio compliance checks stall:
**Vonage**, **MessageBird** — switching would reopen the signed-off decision
with the product owner. The reason the choice was made early is external lead
time: provider identity and business verification can take days and blocks
signup (#10).

Rate limits to configure (Supabase Dashboard, Auth section):

* minimum interval between SMS to the same number: 60s
* OTP expiry: at most 10 minutes
* project-wide SMS-per-hour cap: start low (e.g. 30/h) and raise with usage —
  a runaway loop here is a phone bill and a spam report.

## Human checklist

Two phases, deliberately: staging now, production later. Everything this
ticket can verify runs against staging; production is created only when
something real needs it. Until Phase B runs, the production-facing acceptance
criteria on the ticket stay open — deferred, not done.

Never paste a key into git, an issue, or a chat — each step says where a
secret goes.

### Phase A — staging, now (ordered — do not reorder)

1. **Supabase org.** Create org `pinkas`. Staging can start on the free tier;
   note the free tier pauses idle projects, which is acceptable for staging
   only.
2. **Create `pinkas-staging`** — region **Frankfurt (eu-central-1)** (SDD
   §16.6 applies to staging too: parity, and one residency sentence). Strong
   database password, stored in the password manager.
3. **Hand back the project ref** (refs and URLs are not secrets; keys are) as
   a comment on the ticket.
4. **Local CLI setup:**

   ```bash
   pnpm install
   pnpm exec supabase login        # token lands in your keychain
   pnpm exec supabase init         # creates supabase/config.toml — commit it
   pnpm exec supabase link --project-ref <staging-ref>
   ```

5. **Apply and verify:**

   ```bash
   pnpm exec supabase db push
   ./scripts/verify-live-schema.sh
   ```

6. **Live RLS verification** (real JWTs — the first contact of invariant 1
   with a real auth.uid()). In your shell, set for one session, values from
   the staging dashboard only: LIVE_SUPABASE_URL, LIVE_SUPABASE_ANON_KEY,
   LIVE_SUPABASE_SERVICE_ROLE_KEY. Then:

   ```bash
   PINKAS_LIVE_TEST=staging node scripts/test-live-rls.mjs
   # and when done:
   unset LIVE_SUPABASE_SERVICE_ROLE_KEY
   ```

   Attach the output to the ticket for handoff to `database`. Optional deeper
   pass (real auth.uid() implementation, but GUC-injected claims rather than
   a verified JWT): run `docs/schema.test.sql` over psql against staging.
7. **OTP on staging:**
   1. Create the Twilio account; complete identity/business verification
      early — this is the long pole, and it blocks signup work.
   2. SMS geo permissions: enable Israel (+972). Set a low spend limit.
   3. Create a Verify service, friendly name / sender `Pinkas`.
   4. Supabase Dashboard, Auth, Providers, Phone: enable, select Twilio
      Verify, enter Account SID + Verify Service SID; the auth token goes in
      the dashboard field only.
   5. Set the rate limits listed above.
   6. Send one test OTP to an Israeli number and record delivery (screenshot
      or note) on the ticket.
8. **Staging keys into Vercel** (coordinates with the Vercel ticket):
   staging URL + anon key into preview and development scopes; the staging
   service-role key into preview only if and when a preview actually needs
   the portal path.
9. **Storage buckets** — nothing to create yet; the materials ticket adds
   the private bucket and its policy here when it lands.
10. **pg_cron** — nothing to schedule yet; the nightly risk job (SDD §8.4)
    adds its schedule and monitoring to this runbook when it exists.

### Phase B — production, later (ordered — do not reorder)

Triggers, whichever comes first: real bride data is about to exist (beta
users), or the Vercel ticket is ready to wire the production environment.
Do not create the production project "to have it" — an empty production
project is a standing credential with nothing to protect yet.

1. **Create `pinkas-prod`** — region **Frankfurt (eu-central-1)**, on a paid
   plan from day one: SDD §16.1 requires PITR and real backups, and the free
   tier pauses idle projects. Its own strong database password, password
   manager.
2. **Apply and verify:**

   ```bash
   pnpm exec supabase link --project-ref <prod-ref>
   pnpm exec supabase db push
   ./scripts/verify-live-schema.sh
   ```

3. **Anon check, read-only** (safe on production — needs no service key,
   writes nothing beyond a read attempt):

   ```bash
   PINKAS_LIVE_TEST=prod-anon-only node scripts/test-live-rls.mjs
   ```

   Never run the staging mode against production: it seeds data.
4. **OTP on production** — repeat the Phase A OTP wiring against the prod
   project, same Twilio Verify service, same rate limits.
5. **Keys into Vercel, protection first:** prod URL + anon key into the
   production scope; the prod service-role key goes in **last**, production
   scope only, after the Vercel ticket's deployment protection is on and
   `security` has signed off on the environment matrix as applied.
6. **Restore drill** — before real bride data arrives, perform one PITR
   restore of the prod project to a scratch project and diff the schema
   (SDD §16.1: an untested backup is not a backup). Record the date here.

## Hand back on the ticket

Phase A:

* the staging project ref and its region (text)
* `verify-live-schema.sh` output for staging
* `test-live-rls.mjs` staging output
* OTP delivery evidence
* one sentence per key stating where it currently lives

Phase B, when it runs:

* the prod project ref and region
* `verify-live-schema.sh` output for prod
* `test-live-rls.mjs` prod-anon-only output
* the restore-drill date
