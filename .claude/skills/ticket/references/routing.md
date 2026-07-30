# Routing a ticket to an agent

Pick the agent that owns the **riskiest surface** the slice touches, not the one that writes the
most code. If two agents own equal weight, split the ticket.

## By surface

| The slice touches | Agent |
|---|---|
| `app/(instructor)/`, `app/p/`, `components/`, Tailwind theme, translation layer, fonts, service worker | `frontend` |
| `lib/data/`, `lib/supabase/`, Server Actions, Route Handlers, `app/api/`, auth flows, signed URLs, rate limiting | `backend` |
| `supabase/migrations/`, `docs/schema*.sql`, a table, column, policy, view, index, `pg_cron` | `database` |
| `lib/domain/` — scheduling, risk, hebrew-calendar, templates | `domain` |
| Test coverage, fixtures, Playwright, axe, CI workflows | `qa` |
| Vercel and Supabase project config, environment variables, `.env.example`, deploy and rollback runbooks, how a migration reaches production, DNS | `infra` |
| `docs/SDD.md`, `docs/PRD.md`, `docs/adr/`, `README.md` | `docs` |
| A review of existing work for leaks, RLS, PII, token handling | `security` |

## By story (PRD §6)

| Stories | Usual owner | Note |
|---|---|---|
| A1 signup | `backend` | The seeding transaction is the substance; the form is thin |
| A2 curriculum builder, A3 duplicate | `frontend` | Unless the deferrable-constraint reorder is the hard part — then `database` |
| A4, B3 defaults and referral source | `backend` | |
| B1 wedding date in both calendars | `domain` | Conversion and `wedding_date_source` semantics live in `hebrew-calendar.ts` |
| B2, B4, C5 scheduling and feasibility | `domain` | The engine. The screen that renders it is a separate `frontend` ticket |
| C1 Today screen | `frontend` | The aggregated query behind it is a `backend` ticket |
| C2, C3, C4 session records, private notes, carry-forward | `backend` | Private data — always name invariant 2 in "Invariants in play" |
| C6 who is at risk | `database` | `v_course_risk` is the source of truth; `domain/risk.ts` mirrors it |
| D1 reminders, D2 templates | `domain` for rendering, `frontend` for the one-tap deep link | |
| D3 portal link, E1–E4 portal | `backend` | Token issuance and Path 2. Route a `security` review alongside |
| F1, F2, F3 payments | `backend` | |
| F4 CSV export, erasure, retention | `backend` | |
| G2 mark complete | `backend` | |

## Rules of thumb

* **Anything that changes what the portal can reach is `database` plus a `security` review**, even
  if the diff is one line of SQL. `portal_session_view` and the three private field names are the
  highest-consequence surface in the repo.
* **A new screen is usually two tickets**: the `lib/data/` function (`backend`) and the screen
  (`frontend`), with the second blocked by the first. Resist merging them — the `frontend` agent
  cannot write queries, and a merged ticket forces it to.
* **A new engine behaviour is `domain`, and its fixtures ship with it.** Do not route the tests to
  `qa` separately; `qa` is for coverage gaps, harness work, and flakiness, not for testing a change
  someone else just made.
* **Anything altering `access_log` semantics is `backend`, and always names invariants 3 and 5** —
  completeness of the log is what the whole privacy story rests on.
* **A doc-only change from a resolved product question is `docs`.** A doc change that follows a code
  change belongs in the same ticket as the code, not a separate one.
* **`security` never gets a build ticket.** It has no write tools. Route the fix to the owning
  agent and use `security` to verify.
* **`qa` owns CI; `infra` owns everything downstream of a green build.** The dividing question is
  what the change is *for*: proving the code correct is `qa`, delivering correct code to production
  is `infra`. `ci.yml` stays with `qa` — splitting one file across two owners buys a handoff and
  nothing else.
* **A migration is two tickets when the delivery mechanism is in question.** What the migration
  contains is `database`; how it reaches production is `infra`. Most of the time only the first
  exists.
* **Anything that puts the service-role key somewhere new is `infra` plus a `security` review** —
  including an environment variable. Invariant 5 is enforced by lint inside the codebase and by
  nobody at all outside it.
* **`challenger` is never a routing answer.** It owns no surface and no ticket; it enters through
  the `**Challenge:** yes` field at dispatch time. If you are tempted to route a ticket to it, what
  you actually want is `**Challenge:** yes` on a ticket owned by someone else.
