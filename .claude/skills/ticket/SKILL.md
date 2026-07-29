---
name: ticket
description: Create, route and dispatch Pinkas tickets on GitHub Issues with an owning agent attached up front. Use when the user wants to open a ticket, break work into tickets, assign or change the agent on a ticket, ask which agent should own something, or start work on an existing ticket number.
---

# Ticket

Every Pinkas ticket carries the agent that will own it, decided when the ticket is written rather
than when it is picked up. That is the point: routing is a design decision about which invariants
the work touches, and it is cheapest to make while the work is still being described.

Tracker: GitHub Issues on this repo. Agents live in `.claude/agents/`.

## Modes

`/ticket new <description>` — draft and open a ticket with an agent attached
`/ticket route <n>` — set or change the agent on an existing ticket
`/ticket run <n>` — dispatch the ticket to its attached agent
`/ticket list [agent]` — show open tickets, optionally for one agent

If the user just describes work without naming a mode, assume `new`.

---

## `new`

**1. Route it.** Use `references/routing.md` to pick the owning agent. Pick exactly one — the agent
that owns the *riskiest* surface the slice touches, not the one that writes the most lines. A slice
that adds a column, a query and a screen is `database` if the column changes the isolation surface,
otherwise usually `backend`.

If the slice genuinely has two owners of equal weight, that is a signal it should be **two
tickets** with one blocking the other. Propose the split rather than picking arbitrarily.

**2. Draft the body** using the template below.

**3. Show the user** the title, the agent, the mode (AFK/HITL) and the acceptance criteria, and ask
whether the routing looks right. Routing is the one thing worth confirming — everything else is
editable later on the issue itself.

**4. Open it:**

```bash
gh issue create \
  --title "<title>" \
  --label "agent:<agent>" \
  --body-file <path>
```

Write the body to a temp file rather than passing it inline — the bodies contain backticks and
Hebrew, and shell quoting will mangle them.

If the `agent:*` label does not exist yet, run `./scripts/setup-agent-labels.sh` once.

### Body template

```markdown
**Agent:** `<agent>`
**Mode:** AFK | HITL

## What to build

The end-to-end behaviour of this slice. Not layer-by-layer implementation. Avoid file paths and
code snippets — they go stale. Exception: a type shape or schema that encodes a decision more
precisely than prose can.

## Acceptance criteria

- [ ] …
- [ ] …

## Invariants in play

CLAUDE.md's numbered invariants this slice touches — e.g. "2 (private notes physically separated)".
Omit the section if none apply, but think about it before you omit it.

## Blocked by

#<n>, or "None - can start immediately"
```

The `**Agent:**` line is load-bearing: `.github/workflows/agent-label.yml` parses it and keeps the
`agent:*` label in sync, so the line and the label cannot drift.

---

## `route`

Read the issue, propose an agent with one sentence of reasoning, and on confirmation update both
the label and the `**Agent:**` line in the body. Update both — the workflow syncs the label *from*
the body, so editing only the label will be reverted on the next edit.

---

## `run`

1. `gh issue view <n> --json title,body,labels`
2. Read the agent from the `**Agent:**` line, falling back to the `agent:*` label.
3. If neither is present, run `route` first — do not guess and proceed.
4. Spawn that agent with the Agent tool, passing the issue number, title and full body. The agent
   already has CLAUDE.md and its own definition; do not re-paste either into the prompt.
5. `security` is read-only by design. Dispatching a security ticket produces a findings report, not
   a patch. If the ticket asks for fixes, dispatch the owning agent for the fix and use `security`
   to verify afterwards.

Report back what the agent did and what it left to others.

---

## `list`

```bash
gh issue list --state open --json number,title,labels \
  --jq '.[] | "\(.number)\t\(.labels | map(.name) | map(select(startswith("agent:"))) | join(",") // "unrouted")\t\(.title)"'
```

Flag any open ticket with no `agent:*` label — an unrouted ticket is one nobody has decided the
shape of yet.
