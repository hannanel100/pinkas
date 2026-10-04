# ADR-0011 — The portal token travels in the URL fragment and is exchanged by form POST for a short session cookie

**Status:** Accepted · October 2026 — settled in the #54 design challenge (2026-10-04, [verdict](https://github.com/hannanel100/pinkas/issues/54#issuecomment-5978322257)); to be implemented by #54 before #7 issues the first real link. **Until it ships, the link format in effect is ADR-0005's `/p/<token>`**, and `docs/runbooks/portal-edge.md` §2's "accept, bounded" is the position.
**Relates to:** SDD §2.3, §6.2, §6.3, §12.4 · **supersedes the URL-path aspect of [ADR-0005](./0005-hashed-portal-tokens.md)**; ADR-0005's token generation, hashing, expiry and revocation stand · companion to [ADR-0010](./0010-portal-database-login.md) · glosses PRD D3

## Context

ADR-0005 put the portal token in the URL path, `/p/<token>`. The path is part of the request line, so the token is recorded by every log that records paths. On this host that means Vercel's runtime logs, the Firewall and Observability views (including requests the Firewall refused with 429), and any future log drain. Whoever reads such a log during its retention window holds a credential that stays valid until `wedding_date + 14 days`, which is months. PR #52 (#40) accepted this as an interim position, "accept, bounded", with conditions on who may read the logs. That position is defensible only while the log ACL is one person with one CLI login.

The #52 security review found that the decision could not be deferred. Once #7 sends real links over WhatsApp, changing the format strands every outstanding link until it expires. **The format therefore has to be settled before the first real link is issued**, and that is the only reason this is being decided now rather than when the log ACL grows.

The ticket posed three options:

* **Fragment plus POST.** The token goes after `#`, which browsers never send to any server.
* **GET plus redirect exchange.** `/p/<token>` sets a cookie and redirects to a clean URL.
* **The status quo.**

## Decision

**The link is `https://<host>/p#<token>`.** The fragment is never sent over HTTP, so the token never reaches the host or any of its logs. A link-preview fetcher cannot resolve it either: it fetches `/p`, which carries nothing.

### The exchange

An inline, synchronous script in the server-rendered `/p` shell runs these steps before Next hydrates, so the router never sees the hash:

1. read `location.hash`;
2. `history.replaceState(null, '', '/p')`, removing the token from the address bar and the history entry before any network request;
3. put the token in a hidden field `t` of `<form method="post" action="/p/session">`;
4. call `form.submit()`.

A `hashchange` handler runs the same steps. It covers a WhatsApp link re-opened into a tab that is already at `/p`, which is a same-document navigation and does not reload the page.

**`/p/session` is a Route Handler, and it always answers `303 See Other → /p`.** It gives the same answer on success and on every failure:

* a malformed, unknown, expired, revoked or soft-deleted token;
* the DB rate limit tripped;
* a wrong `Sec-Fetch-Site`;
* a wrong content type, an extra field, or a body over 128 bytes.

Only `Set-Cookie` differs: it sets the session cookie on success and clears it on failure. A test byte-compares status, `Location` and body across success and every failure class. The handler always hashes the token, always calls the rate-limit counter, and always runs the lookup, so the work done does not depend on which check fails. The counter is `portal_rate_limit_hit`, keyed by an HMAC of the IP and a prefix of the token's **hash**, and it is called once per exchange, before the lookup.

**CSRF.** The handler rejects the request unless `Sec-Fetch-Site: same-origin`. When the header is absent, as on older browsers, it accepts. A strict `Origin` equality check would fail: `/p` is served with `Referrer-Policy: no-referrer`, and under that policy a form POST sends `Origin: null`. **The accepted residual is login-CSRF on older browsers only.** An attacker page could submit *its own* token and drop the victim into the attacker's portal. That exposes nothing of the bride's.

* *Optional hardening, not adopted:* serve `/p` with `Referrer-Policy: same-origin`, so that `Origin` can serve as a second check. If this is ever adopted, the change must record why `/p` differs from the `no-referrer` rule of SDD §6.2.

### The session cookie

| Property | Value |
|---|---|
| Name | `__Secure-p` |
| Flags | `HttpOnly; Secure; SameSite=Strict; Path=/p`; no `Domain` |
| Lifetime | `Max-Age = min(1800 s, time to portal_expires_at)`. **Not sliding**: a render does not extend it |
| Value | `v1.<b64url(sha256(token))>.<exp>.<HMAC>`, the MAC under `PORTAL_SESSION_KEY`. **Never the token itself** |
| Rotation | two keys are accepted at once, so the key can be rotated without logging every bride out |

**Each render verifies the MAC, then looks the bride up by `portal_token_hash`** through `portal_resolve_token` and `portal_sessions` (ADR-0010). A bad MAC is rejected before the database is touched. Because the lookup happens again on every render, revocation, expiry and token regeneration take effect on the next render, whatever the cookie says. Renders do not call the rate-limit counter. Each lookup writes its own `('bride_portal', bride_id)` row inside the database (ADR-0010 §2), so neither the exchange nor the render calls `logAccess`.

`SameSite=Strict` means the cookie is not sent on the first, cross-site GET from WhatsApp. That does not matter, because every entry from a link re-exchanges from the fragment.

### Everything else about the route

* **`/p/<anything>` returns 404.** There is no compatibility handler: a redirect from the old shape would put the token back in a request line. No real links exist yet, so nothing is stranded.
* **With JavaScript disabled,** the page shows a neutral `<noscript>` line and nothing else. A paste-the-link form was rejected, because it would invite the token into a field and from there into autofill.
* **Headers on `/p` and `/p/session`:** `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex, nofollow`, `Cache-Control: no-store, private`.
* **Edge rate limits (#40)** match `path == /p` *or* a path starting with `/p/`, plus a stricter rule on `POST /p/session`. The old condition, "starts with `/p/`", does not match `/p` at all.

### What "קישור חד-פעמי" means (PRD D3)

D3's acceptance line reads *קישור חד-פעמי, בלי סיסמה*. Both sides of the exchange conceded the reading: **one link, no password, reusable until `portal_expires_at`.** "חד-פעמי" means she is sent it once, not that it works once.

A single-use link was rejected. It breaks the bride's second visit, and she has two to five in total (PRD §3.3). It is also consumed by whatever opens it first: a preview fetcher or a corporate link scanner can use up a single-use link before she taps it. PRD D3 carries a gloss pointing here.

## Alternatives rejected

**GET plus redirect exchange.** Needs no client JS, but the token is still in the request line of the first GET, **on every open**. The exposure is per open, not per link, so this changes nothing a log reader cares about.

**The status quo ("accept, bounded").** Safe only while the log ACL stays one person with one CLI login. Every condition in `portal-edge.md` §2 is a promise about the future made to a log nobody controls the contents of. Rejected as the long-term position. It remains the position in effect until this ships.

**The token in a query string.** Hosts log query strings as well as paths.

**No session: the POST response is the portal.** This avoids the cookie, but a reload re-POSTs or loses the page, and the browser's resubmit prompt is the opposite of discreet. The 303 exists to end history at a clean `GET /p`.

**A single-use link bound to the device.** See D3 above.

**An OTP, or anything the bride must know.** PRD §3.3 states as fact that she will not create an account or remember a password. A second factor is exactly what that rules out.

**The owner's opening mechanics: `fetch()` to `/p/session`, then `location.replace('/p')`, guarded by an `Origin` check.** The second round replaced this with the top-level form POST and 303. With that change the cookie is set on a navigation response rather than on a script-initiated one, and the page ends on a server redirect rather than on a second script step. The `Origin` check fell with it, for the `Origin: null` reason above. The verdict records the replacement but not every argument for it. Anyone proposing to return to `fetch()` should re-run the device checks below against it, not assume they carry over.

**Also rejected in the owner's approach:** a Server Action instead of a Route Handler, which gives less control over status, headers and byte-uniform bodies; a split `/p/<id>#<secret>`, which gives previews something to resolve; `/p/#…`, which costs a 308; the token in the cookie; `sessionStorage`, which page script can read; and keeping the fragment for reload, which puts the token in history.

## Consequences accepted

**Why no server-side session table.** The exchange corrected the owner's reasoning here, and the correction is recorded so the wrong version is not repeated. The grounds are:

* no migration;
* no database write per open beyond `access_log`;
* regenerating the token revokes every open session at once, because each render looks up by hash;
* a database dump without `PORTAL_SESSION_KEY` cannot forge a session.

The earlier argument, that a session table would add "a per-open row linking a bride to a time", was wrong. `access_log` already records every open, by design (PRD §10.1).

**`PORTAL_SESSION_KEY` is a new long-lived secret, as sensitive as the database.** Anyone who holds it and a token hash, which is readable in any cookie and in any dump, can mint a session for that bride. It is therefore treated as tier-one: it is kept out of preview and development scopes, it is rotated with two keys accepted at once, and it gets a row in the environment matrix (`infra`). It cannot read anything on its own. A forged cookie still goes through ADR-0010's functions, which require `PORTAL_DATABASE_URL`, and through the expiry and revocation checks on every render.

**The portal needs client JavaScript.** It is one inline script of a few lines, with no framework dependency, and it is the only way to read a fragment. Without JavaScript the bride sees a neutral line and no portal. This is accepted: the fallback would have to put the token somewhere the server sees it, which is the thing this ADR removes.

**WhatsApp link previews show nothing.** The sender-side preview fetcher can fetch only the token-free `/p` shell, so the preview shows the shell's neutral title (SDD §6.3). It cannot resolve the bride, and a `GET /p` does not touch the DB counter. This is a discretion gain, not a cost.

**Back, forward and reload.** History ends at `/p` with no hash. Back leaves the site, and `no-store` keeps the page out of the back/forward cache. Reload within the cookie's 30 minutes renders the portal. After that, `/p` shows a neutral "open the link you received" page, and re-opening the WhatsApp link re-exchanges. A bookmark or home-screen icon saves `/p`, which works only while the cookie lives. That is accepted: the link in the chat thread is the way back in. The E2E suite asserts each of these behaviours: no hash after load, reload, back leaving the site, `hashchange` re-entry, and `/p/<x>` returning 404.

**The token is still in the chat thread.** It is in the WhatsApp message, as in every design. This ADR keeps it out of the host's logs, not out of the phone. ADR-0005's residual risk about forwarding stands unchanged.

**The cookie appears in request headers.** The cookie (hash, expiry, MAC) is sent on every portal request. If Vercel logs request headers, a log reader learns a hash. The MAC stops that hash from becoming a session without the key, and ADR-0010 stops it from reaching the database without the portal credential. Whether Vercel logs headers or bodies at all is unverified and belongs to `infra`, in `portal-edge.md`.

**Still to verify on Android and iOS devices** before #7 issues a real link:

* WhatsApp's linkifier keeps the `#` fragment when it turns the text into a link;
* the cookie set on the 303 persists in WhatsApp's in-app browser, Chrome Custom Tabs and Safari;
* Chrome's *global* history records `/p`, not `/p#<token>`. This is the weakest point and is unconfirmed.

Also unverified: that the inline script reliably runs before Next's hydration. A test covers it. Which header Vercel uses as the trusted client IP is also unverified.

**ADR-0005 is amended, not rewritten.** Its decision table's first sentence, "an opaque random token in the URL path (`/p/<token>`)", and its "Requests are resolved…" paragraph (ADR-0010) no longer describe the design. A pointer at the top of ADR-0005 says so. Its text is unchanged, as the record of what was decided at the time.
