# ADR-0007 — `wa.me` deep links, not the WhatsApp Business API

**Status:** Accepted for Phase 1 · July 2026
**Relates to:** SDD §14, §20.2

## Context

WhatsApp is where this product's messages already live. PRD §4.4 is explicit about the posture: **"WhatsApp is the channel, not the system. We do not try to replace it — we connect to it."**

Sending a reminder is the most frequent action in the product. Wireframe note a4: *the most common action must be the shallowest* — one tap from the Today screen, no intermediate screen.

Two ways to do it: a `wa.me` deep link that opens the user's own WhatsApp with text pre-filled, or the WhatsApp Business API, which sends messages programmatically.

## Decision

Phase 1 uses `wa.me` deep links.

```
https://wa.me/<e164-phone>?text=<url-encoded rendered template>
```

The instructor taps once, WhatsApp opens on the thread with the message composed, and she presses send.

## Why not the Business API

It is the technically superior mechanism and it is the wrong choice here:

- **Meta Business verification.** The persona (PRD §3.1) is a mother of three for whom instruction is secondary income and who uses WhatsApp, Bit and Google Calendar. Requiring her to complete Meta business verification to send a reminder would lose most of the user base at onboarding.
- **Template pre-approval.** Business API messages outside a 24-hour window must use templates approved by Meta. Story D2 — *"I edit my own message templates"* — becomes an approval queue.
- **Per-message cost** against a product whose realistic ARPU is ₪40–70/month (PRD §11.3).
- **It changes who is speaking.** A Business API message arrives from a business account, not from Michal. For a relationship this personal, the message should come from her own number, in her own thread.

That last point is the strongest, and it is not a cost — it is a reason the deep link is *better* here, not merely cheaper.

## Consequences

**Good.** Zero setup, zero cost, no verification. The message comes from her own number, in the existing thread, where the bride already expects it. She can edit before sending, which she often should. Fully aligned with PRD §4.4.

**The real cost: delivery cannot be confirmed.**

A deep link is fire-and-forget. The system cannot know whether she pressed send, edited the text first, or closed WhatsApp and forgot.

Therefore:

- `message_log.status` is **`composed`**, never `sent`.
- The UI never displays a delivery checkmark or anything that reads as one.
- Story D4 — *"I see what was sent and when"* — is **partially satisfied**. The log shows what was composed and when, which is the truth.

This is recorded as a known gap in SDD §20.2 rather than papered over. A "sent ✓" that actually means "we opened WhatsApp" would be a small lie in exactly the place — messages to clients — where the product cannot afford one, and it would be discovered by the user the first time a bride says she never got the reminder.

**Also.** No automatic reminders in Phase 1 — a deep link requires a human tap by definition. Scheduled automated reminders appear in PRD §13 phase 2 and would need either the Business API or a push notification prompting her to send. The latter respects §4.4 and is the recommended Phase 2 approach.

## Revisit when

An organisation partnership (PRD §11.4) brings instructors who would accept business verification, or automated reminders prove necessary rather than desirable. Phase 3. `message_log` already carries a `channel` enum and a status field, so adding a second sending mechanism alongside this one requires no migration.
