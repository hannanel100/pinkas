# ADR-0005 — Hashed opaque portal tokens, not JWT magic links

**Status:** Accepted · July 2026
**Relates to:** SDD §6.2, §12.4

## Context

The bride is a end user, not a customer (PRD §3.3). She will enter 2–5 times in total, mostly to check when the next session is. She **will not create an account, will not remember a password, and will not install an app** — the PRD states this as fact, not preference.

Story E1 requires entry by link with no signup. Story E4 requires access to close after the wedding.

A further requirement makes this more than a convenience problem. PRD §3.3 and §10 identify **discretion as critical**: her phone is not always private. A link that reveals its subject matter — in a URL, a page title, a notification preview — is a real problem for a real person, not a theoretical one.

## Decision

An opaque random token in the URL path (`/p/<token>`), with:

| Property | Choice |
|---|---|
| Generation | 32 bytes from a CSPRNG, base64url |
| Storage | **SHA-256 hash only**, in `bride.portal_token_hash` |
| Lookup | Hash the incoming token, indexed equality match on the hash |
| Expiry | `portal_expires_at`, default `wedding_date + 14 days` |
| Revocation | Null the hash; regenerating issues a new token and invalidates the old |
| Rate limiting | Per IP and per token prefix |
| Headers | `noindex, nofollow`; `Referrer-Policy: no-referrer` |

Requests are resolved server-side by `lib/data/portal.ts`, the only module permitted to construct a service-role client, which then queries `portal_session_view` with an explicit `bride_id` filter (SDD §5).

## Why hash the token

The token is bearer credential: whoever holds it gets in. Storing it in plaintext means a database disclosure hands the attacker working links to every bride's portal — a second breach riding on the first, and precisely the compounding failure PRD §10.1 describes.

Hashing costs nothing here, because the token never needs to be read back. It is displayed once at issuance and re-sent by regenerating. Lookup by hash is an indexed equality match, so it is also fast and gives no timing signal.

## Why not a JWT

A signed JWT would avoid the database lookup, and is the reflexive choice. Rejected because:

- **Revocation.** A JWT is valid until it expires. There is no way to withdraw access to a link that was forwarded to the wrong WhatsApp group without rotating a signing key and invalidating every bride's link at once.
- **Length.** A JWT is a long, conspicuous URL. An opaque 43-character token is shorter and reads as nothing in particular — which matters when the link sits in a WhatsApp thread on a shared phone.
- **Content.** A JWT's payload is base64, not encrypted. Anyone can decode it. Any claim placed there — a bride id, an instructor name — is legible to anyone who sees the URL.
- We need the database row on every request anyway, to check expiry and revocation. The lookup a JWT saves is one we still have to make.

## Consequences

**Good.** Instant revocation. Short, unrevealing URLs. A database disclosure yields hashes, not access. Expiry is a column, which lets the portal *display* its own expiry date — plate 04 shows this, and note d4 makes the point that a stated expiry is a promise, not a restriction.

**Costs.** A database lookup per portal request, which is one indexed hit. A lost link cannot be recovered, only reissued — acceptable, since reissuing is one tap for the instructor and the bride's route to a lost link is to ask her anyway.

**Residual risk, stated plainly.** The link is a bearer token: forwarding it grants access. Mitigated by short expiry, revocation, and the fact that what lies behind it is deliberately minimal — a date, a time, a place, and shared files (SDD §5). Nothing behind the link is worth much to anyone who obtains it, which is itself a security property and a reason not to enrich the portal later.
