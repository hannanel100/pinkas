# Runbook — the portal path at the edge (issue #40)

Two exposures of `/p/[token]` that live outside the codebase, where no lint rule
reaches: request floods against the token lookup, and the token sitting in the
host's own logs. `infra` owns both; `security` reviews the outcome, and nothing
here is settled until that review is recorded on #40.

The portal link is a credential belonging to a named woman. The consequences
of it leaking are hers.

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
responses across tokens (must be identical, and must not echo the token). It
uses random tokens unless a staging token is supplied. Tested against a local
mock limiter only; it has not yet run against Vercel.

## 2. Portal tokens in the host's logs

### The exposure

The token is in the URL **path**, so it is recorded wherever the host records
paths:

* Vercel **runtime logs** (request path per function invocation, plus anything
  the code itself logs — which must never include the token; #7).
* Vercel **Firewall / Observability** traffic views.
* Any **log drain**, analytics, Speed Insights or observability integration —
  none exist on this project today.
* Vercel's own internal retention for abuse and billing, which is outside our
  visibility and governed by its DPA.

SDD §6.3 handles third parties and referrers. It does not handle the host. This
section does.

### Decision (proposed, pending `security` review): accept, bounded

**Accept the token in Vercel's own logs, with the conditions below. Do not
accept it anywhere else.**

Why acceptance is defensible here, rather than merely convenient:

1. **The host gains nothing new.** Vercel terminates TLS and executes the
   function: it already sees every portal request and response in plaintext,
   including the page the token unlocks. A token in its log grants the vendor
   no access it did not already have.
2. **Log readers gain nothing new — today.** The project's only member is its
   owner, who can deploy code, and deployed code can read the service-role key
   at runtime. Log access is therefore not a wider circle than credential
   access; it is the same circle. This argument holds only while every member
   can deploy: a read-only (Viewer-style) member could read live tokens in the
   logs without being able to reach the key, and adding one reopens this
   decision.
3. **Retention is short and finite.** Runtime logs are kept for a bounded
   period by plan — at the time of writing, about **1 hour on Hobby and 1 day
   on Pro**, and up to 30 days only with Observability Plus. A logged token is
   live for at most that long *in the log*; the token itself expires at
   `wedding_date + 14 days` and can be revoked at any time (SDD §6.2).

**Retention window accepted:** the runtime-log retention of the plan in use, as
observed in the dashboard during the checklist below — expected **≤ 1 day**.
The observed value is recorded on #40. Any change that lengthens it is a
change to this decision.

What would make the exposure real is the token **leaving** the host's logs. So
the conditions are the decision:

* **No log drains** on this project. Adding one is a `security`-reviewed change
  and must drop or truncate `/p/` paths before export.
* **No Web Analytics, Speed Insights, Observability Plus or third-party
  observability integration** without the same review. They either record
  paths or extend retention.
* **Never copy a `/p/` log line** into an issue, PR, chat or support ticket.
  When sharing a log, redact the path to `/p/<redacted>`.
* **Team membership on the Vercel project is the log ACL.** Today it is one
  person. Adding a member widens who can read live tokens — note it on #40.
* Application code never logs the token, its prefix, or an error message
  containing either (#7's acceptance criteria).

### Alternatives considered

* **Scrub or truncate paths in the host's logs.** Vercel offers no path
  redaction for its own runtime logs; this is only possible for data we export
  (log drains), and the decision above forbids exporting it at all.
* **Move the token out of the path** — for example into the URL fragment
  (`/p#<token>`), which browsers never send to any server and so never reaches
  any log. This is the only option that removes the exposure entirely. It is
  also a product-visible change to how the link works and needs client-side
  code to read the fragment and post it, which cuts against the portal's
  minimal server-rendered design (SDD §12.4). **Not this ticket's call.** If
  `security` rejects the bounded acceptance, route it as a `backend` ticket
  with `**Challenge:** yes`, touching ADR-0005.
* **Query string instead of path.** No better: hosts log query strings too.

### Revisit when

* a log drain or observability vendor is proposed;
* the Vercel project gains a second member;
* the plan changes (retention changes with it);
* the portal moves off Vercel;
* a portal link is believed leaked — regenerate that bride's token first, then
  reopen this.

## Human checklist

Requires the Vercel project from [vercel.md](./vercel.md) (#28) to exist.

1. **Rules.** Project, Firewall, Configure (Custom Rules), add:
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

   Paste the output on #40. If you probe a protected preview instead, export
   `VERCEL_AUTOMATION_BYPASS_SECRET` in your shell for that run only (only if
   one exists; see vercel.md) and unset it after.
3. **Re-verify with a resolving token once #7 ships** — against staging data
   only. In your shell, for one run, export `PORTAL_PROBE_VALID_TOKEN` with a
   **staging** bride's live token, re-run step 2 against a preview, then
   `unset PORTAL_PROBE_VALID_TOKEN`. Never a production bride's token.
4. **Observe what the logs record.** Open `https://<production-domain>/p/probe-not-a-token`
   in a browser, then Project, Logs: confirm what is shown for that request
   (full path? query?). Note the retention period the Logs view states for
   your plan. Record both on #40 — this replaces the "at the time of writing"
   numbers above with observed ones.
5. **Confirm the conditions hold:** Settings, Log Drains — none; Analytics and
   Speed Insights — disabled; Integrations — none that ingest logs or traces;
   Members — who is listed. Record on #40.
6. **`security` reviews** this runbook and the evidence from steps 2–5.
