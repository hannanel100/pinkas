# Runbook — the portal path at the edge (issue #40)

Two exposures of `/p/[token]` that live outside the codebase, where no lint rule
reaches: request floods against the token lookup, and the token sitting in the
host's own logs. `infra` owns both; `security` reviews the outcome, and nothing
here is settled until that review is recorded on #40.

The portal link is a credential belonging to a named woman. The consequences
of it leaking are hers.

> **The link format is changing — [ADR-0011](../adr/0011-portal-link-in-the-fragment.md)
> (settled 2026-10-04, #54).** The link becomes `/p#<token>`. The token sits in
> the fragment, which never reaches the host, and is exchanged by
> `POST /p/session` for a session cookie. `/p/<anything>` becomes a 404. Until
> #54 ships, everything below describes the deployed `/p/<token>` shape. Where
> a rule changes when it ships, the section says so. No real link is issued
> under the old shape (#54 blocks #7).

## 1. Edge rate limiting on `/p/*`

### Layering

| Layer | Keyed by | Owner | Purpose |
|---|---|---|---|
| **Edge** — Vercel Firewall rate-limit rules (this runbook) | client IP | `infra` | Primary. Absorbs floods before a function runs or the database is touched. |
| **Database** — fixed-window counter (#37) | prefix of the token's **hash**, never of the token | `database` / `backend` | Backstop for what gets through: many IPs walking the same bucket. |
| In-memory counters in the app | — | — | **Not used.** Each serverless instance would keep its own count; the limit would be whatever the concurrency happened to be. |

The edge cannot key by token prefix: it would have to see the token, and a
prefix of a credential is a partial credential. Per-token bucketing therefore
lives only in the database layer, over the hash. The two layers are
complementary, not redundant; their thresholds are set independently.

### What the limit is for — stated honestly

A portal token is 32 random bytes (SDD §6.2). Guessing one is infeasible at any
request rate, so **the rate limit is not what protects the token** — its
entropy is. The limit bounds three things: function and database cost under a
flood, log noise that would hide a real incident, and the usefulness of the
endpoint as an oracle if a token is ever partially leaked. That is why the
thresholds below can be generous enough never to touch real use.

### Thresholds

Two rules, both on the condition **Request Path starts with `/p/`**, counted
**per IP**, fixed window, action **Rate limit → 429**:

| Rule | Window | Limit | Catches |
|---|---|---|---|
| `portal-burst` | 60 s | **30** requests | scripted bursts |
| `portal-sustained` | 600 s | **120** requests | slow, steady enumeration that stays under the burst rule |

If the plan does not offer a 600 s window, use the longest offered and scale the
limit to keep the same rate (12 per minute averaged).

**When ADR-0011 ships, the condition changes.** "Starts with `/p/`" does not
match `/p` itself, and `/p` is where every portal page is served after the
change. Both rules must match **Request Path equals `/p` OR starts with
`/p/`**. A third, stricter rule is added on **`POST /p/session`**, the only
request that carries a token. The owner's approach proposed about 10 per
minute per IP; `infra` sets the number against the envelope below. The
envelope changes too: a bride's open becomes three requests (`GET /p`,
`POST /p/session`, `GET /p` after the 303), and a preview fetch becomes one
`GET /p`, which never touches the database. Re-check the burst limit against
that before publishing.

### Why these numbers — the legitimate envelope

| Pattern | Requests to `/p/*` from one IP | Source |
|---|---|---|
| A bride opening her link | 1 per open (the portal has no navigation, so no prefetches; static assets are under `/_next`, not `/p`) | SDD §12.4 |
| A bride refreshing anxiously | ≤ 5 in a minute | assumption, generous |
| Real usage over months | several opens a week — never more than a handful inside any 10-minute window | PRD §3.3, #40 |
| An instructor composing reminders | WhatsApp builds the link preview **on the sender's phone**, so composing a message that contains a portal link fetches it from *her* IP. A morning batch of 15 reminders in a minute is 15 requests | ADR-0007 |
| Shared IPs | Israeli mobile carriers use CGNAT; several unrelated users may share one IP. Phase-1 portal traffic is a few hundred brides in total, so overlap inside one window is rare | — |

The worst legitimate case is about 20 requests in a minute from one IP — the
instructor's batch plus a refresh. The burst limit sits at 1.5× that and the
sustained limit at 6× it. Because both windows are at most ten minutes, **no
pattern spread over weeks or months can accumulate toward a limit**: the
long-horizon behaviour the ticket worries about reduces to "what happens inside
one window", which the probe below tests directly.

The attacker's budget under these limits is about 17,000 requests per IP per
day — irrelevant against 2^256, and the cost bound is the point.

### Degrading safely

* The firewall decides **before the request reaches the application**, on the
  IP alone. It cannot know whether the token is valid, so a 429 carries no
  validity signal by construction — valid, expired, revoked and garbage tokens
  are counted and refused identically.
* The 429 is the host's error page, not ours, so `next.config.ts`'s
  `Referrer-Policy: no-referrer` does not apply to it. The browser's default
  policy (`strict-origin-when-cross-origin`) still sends only the origin
  cross-origin, never the path, so following a link on that page does not
  leak the token. Whether the page echoes the path is unverified until the
  probe runs against a real deployment — it fails if it does.
* Whatever the application-layer limit (#37) returns when *it* trips must be
  equally uniform; that is `backend`'s to enforce in `lib/data/portal.ts` (#7),
  alongside the valid/expired/revoked/malformed indistinguishability it
  already requires.
* **Incident lever:** if a distributed flood gets past per-IP limits, turn on
  Attack Challenge Mode (Firewall). It will also break WhatsApp link previews
  while on; turn it off after.

### Verification — against a real deployment, not this file

`scripts/probe-portal-rate-limit.sh` sends the legitimate envelope (must see
zero 429s), then bursts past the limit (must see a 429), then compares limited
responses across tokens (must be identical, and must not echo the token), then
tries alternative spellings of the path (`//p/`, `/%70/`, `/P/`) while limited
— each must be refused, 404, or redirect into `/p/`, never served. It uses
random tokens only (checklist step 2 explains why there is no valid-token
run). Tested against local mock servers only; it has not yet run against
Vercel.

## 2. Portal tokens in the host's logs

### The exposure

The token is in the URL **path**, so it is recorded wherever the host records
paths:

* Vercel **runtime logs** (request path per function invocation, plus anything
  the code itself logs — which must never include the token; #7).
* Vercel **Firewall** traffic and logs — including requests the firewall
  **refused with 429**. Those never reach a function, so they are absent from
  runtime logs but present here: a bride who trips the limit has her token
  recorded in the firewall's view, not the function's.
* Vercel **Observability** views (request paths or route-level aggregates,
  depending on the view and plan).
* Any **log drain**, analytics, Speed Insights or observability integration —
  none exist on this project today.
* Vercel's own internal retention for abuse and billing, which is outside our
  visibility and governed by its DPA.

SDD §6.3 handles third parties and referrers. It does not handle the host. This
section does.

### After ADR-0011 ships: not applicable — the token never reaches the host

Once the link is `/p#<token>`, the token is never in a request line. Browsers
do not send the fragment. The exchange carries the token in a POST body, and
request bodies are not logged. Every other request carries only the session
cookie. **Nothing in this section's exposure list then records a token**, and
the decision below lapses for links issued under the fragment scheme.

**The residual question: the cookie in a request header.** The `__Secure-p`
cookie, which holds the token hash, its expiry and a MAC, is sent on every
portal request. If any surface above logs request headers, a log reader learns
a hash. The MAC stops that hash from becoming a session without
`PORTAL_SESSION_KEY`. [ADR-0010](../adr/0010-portal-database-login.md) stops it
from reaching the database without `PORTAL_DATABASE_URL`. **Whether Vercel logs
request headers or bodies on any surface is unverified.** Checklist step 3
records it when it runs. If headers are logged, record the retention and treat
the cookie as this section treats the path today, as bounded by those two
secrets.

**Until ADR-0011 ships**, the decision below remains the position.

### Decision (proposed, pending `security` review): accept, bounded

**Accept the token in Vercel's own logs, with the conditions below. Do not
accept it anywhere else.**

Why acceptance is defensible here, rather than merely convenient:

1. **The host gains nothing new.** Vercel terminates TLS and executes the
   function: it already sees every portal request and response in plaintext,
   including the page the token unlocks. A token in its log grants the vendor
   no access it did not already have.
2. **Log readers gain nothing new — today, and only if checked.** The argument
   is that everyone who can read the logs can already reach the service-role
   key (by deploying production code that reads it), so log access is not a
   wider circle than credential access. That holds only if **every** log
   reader below can deploy to production. The readers are:
   * **project / team members, every role.** A Viewer-style member, or a
     Developer-role member who can read production logs but cannot deploy to
     production or read production variables, breaks the argument;
   * **Vercel access tokens** — personal tokens of any member (including the
     one `vercel login` creates for the CLI), and any `VERCEL_TOKEN` stored as
     a GitHub Actions secret or anywhere else. A token reads logs over the API
     with its owner's rights, from wherever it is stored;
   * **integrations** granted log, trace or observability scopes.

   Today the project has one member, its owner, and is meant to have no
   tokens beyond the owner's CLI login and no integrations. Checklist step 4
   verifies this rather than assuming it; any other reader reopens this
   decision.
3. **Retention bounds how long a token can be *found*, not how long it
   *works*.** Each surface keeps logs for a bounded, plan-dependent period —
   at the time of writing, runtime logs about **1 hour on Hobby and 1 day on
   Pro**, up to 30 days with Observability Plus; firewall and observability
   retention must be read off the dashboard (checklist step 3). But a token
   copied out of a log in that window **stays valid until `wedding_date + 14
   days`** — typically **months** — unless the instructor regenerates it
   (SDD §6.2). Retention limits the window of discovery; it does not limit the
   exposure once discovered.

**Retention windows accepted:** for **each** surface that records `/p/<token>`
— runtime logs, firewall logs (including 429-refused requests), observability
views — the retention of the plan in use, as observed in the dashboard in
checklist step 3 and recorded per surface on #40. Expected ≤ 1 day for runtime
logs; the others are unknown until observed. Any change that lengthens any of
them is a change to this decision.

What would make the exposure real is the token **leaving** the host's logs. So
the conditions are the decision:

* **No log drains** on this project. Adding one is a `security`-reviewed change
  and must drop or truncate `/p/` paths before export.
* **No Web Analytics, Speed Insights, Observability Plus or third-party
  observability integration** without the same review. They either record
  paths or extend retention.
* **Never copy a `/p/` log line** into an issue, PR, chat or support ticket.
  When sharing a log, redact the path to `/p/<redacted>`.
* **Members, access tokens and integrations together are the log ACL.** Today
  that is one person and their CLI login. Adding a member of any role, minting
  a token (including a `VERCEL_TOKEN` for CI), or granting an integration log
  access widens who can read live tokens — it reopens this decision on #40.
* Application code never logs the token, its prefix, or an error message
  containing either (#7's acceptance criteria).

### Alternatives considered

* **Scrub or truncate paths in the host's logs.** Vercel offers no path
  redaction for its own runtime logs; this is only possible for data we export
  (log drains), and the decision above forbids exporting it at all.
* **Move the token out of the path** into the URL fragment (`/p#<token>`),
  which browsers never send to any server. Client code reads the fragment and
  exchanges it by **POST** — request bodies are not logged — for a session.
  This is the only option that removes the exposure entirely. A half-measure
  does not: a `GET /p/<token>` that sets a cookie and redirects to a clean URL
  still logs the token once, on that first request, which is all a log reader
  needs.

  It is also a product-visible change to how the link works, needs
  client-side code on a deliberately minimal server-rendered page (SDD
  §12.4), and touches ADR-0005. **Not this ticket's call — but not an "if
  `security` objects later" question either.** Once #7 issues the first real
  link, changing the link format means reissuing every link already sent over
  WhatsApp. **The path-vs-fragment decision must be made before #7 issues a
  real link.** It is being routed separately; the "accept, bounded" decision
  above is provisional until it lands, and is moot for links issued under a
  fragment scheme if that is the outcome.

  **Settled 2026-10-04 (#54, [ADR-0011](../adr/0011-portal-link-in-the-fragment.md)):
  the fragment won**, with a top-level form POST and a `303 → /p`.
* **Query string instead of path.** No better: hosts log query strings too.

### Revisit when

* a log drain or observability vendor is proposed;
* the Vercel project gains a member of any role, a Vercel access token is
  created beyond the owner's CLI login, or an integration gets log access;
* the plan changes (retention changes with it);
* the portal moves off Vercel;
* a portal link is believed leaked — regenerate that bride's token first, then
  reopen this.

## Human checklist

Requires the Vercel project from [vercel.md](./vercel.md) (#28) to exist.

1. **Rules.** *(When ADR-0011 ships, the condition and rule set change — see
   "When ADR-0011 ships" in §1. The steps below are for the current
   `/p/<token>` shape.)* Project, Firewall, Configure (Custom Rules), add:
   * `portal-burst`: If *Request Path* *starts with* `/p/` → *Rate Limit*,
     fixed window **60 s**, **30** requests, keyed on **IP**, action
     **429 Too Many Requests**.
   * `portal-sustained`: same condition and key, window **600 s**, **120**
     requests, action **429**.
   * Publish. If rate limiting is unavailable on the current plan, stop and
     record that on #40 — this is the plan decision in vercel.md step 1.
2. **Verify against the deployment** (production domain, from an operator
   machine — the probe rate-limits your own IP for up to ten minutes):

   ```bash
   ./scripts/probe-portal-rate-limit.sh https://<production-domain>
   ```

   *When ADR-0011 ships, the probe moves to `GET /p` and `POST /p/session`
   with random bodies. A random path under `/p/` then tests the 404, not the
   lookup. The script change is `infra`'s, with #54.*

   Paste the output on #40. If you probe a protected preview instead, and a
   bypass secret exists (see vercel.md), enter it without echoing it or
   leaving it in shell history, for that run only:

   ```bash
   read -rs VERCEL_AUTOMATION_BYPASS_SECRET; export VERCEL_AUTOMATION_BYPASS_SECRET
   ./scripts/probe-portal-rate-limit.sh https://<preview-deployment-url>
   unset VERCEL_AUTOMATION_BYPASS_SECRET
   ```

   There is deliberately **no step that probes with a resolving token.** The
   firewall decides on the IP alone, before the request reaches the app, so a
   valid token cannot change the edge's response — the probe's random tokens
   already exercise everything the edge does. And no environment both sits
   behind the firewall and resolves a token we may use: previews hold no
   service-role key (vercel.md), a staging token is invalid on production, and
   a real production bride's token must never be used for testing.
   Validity-hiding when the **application-layer** limit (#37) trips belongs in
   #7/#25's integration tests, where a resolving fixture token exists. The
   probe keeps an optional `PORTAL_PROBE_VALID_TOKEN` input — checked, like
   the random ones, for not being echoed in the limited response — for the day
   such an environment exists; if used, enter it with `read -rs` as above.
3. **Observe what each surface records, and for how long.** Open
   `https://<production-domain>/p/probe-not-a-token` in a browser; step 2 has
   already tripped the limit once. For **each** of Logs (runtime), Firewall
   (traffic / logs, including the 429-refused requests) and Observability,
   record on #40 whether `/p/<token>` appears in full, and the retention the
   view states for your plan. Record also whether any surface shows request
   **headers** or **bodies** — the residual question once ADR-0011 ships
   (§2). This replaces the "at the time of writing"
   numbers above with observed ones.
4. **Confirm the conditions hold**, recording each on #40:
   * Settings, Log Drains — none.
   * Analytics, Speed Insights, Observability Plus — disabled.
   * Integrations — none with log, trace or observability access.
   * Team / project members — list them **with their roles**; every one must
     be able to deploy to production (decision point 2).
   * Access tokens — Account Settings, Tokens, for **every** member: token
     names and scopes; only the owner's CLI login is expected.
   * GitHub — `gh secret list --repo hannanel100/pinkas` (prints names only):
     no `VERCEL_TOKEN` or other Vercel credential, unless #25 has added one
     with `security`'s review — in which case it is a log reader too.
5. **`security` reviews** this runbook and the evidence from steps 2–4.
