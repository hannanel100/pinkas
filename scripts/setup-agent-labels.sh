#!/usr/bin/env bash
# Creates the agent:* label set used to route tickets to their owning agent.
# Idempotent — re-running updates colours and descriptions in place.
#
#   ./scripts/setup-agent-labels.sh

set -euo pipefail

create() {
  local name="$1" color="$2" desc="$3"
  if gh label list --limit 200 --json name --jq '.[].name' | grep -qx "$name"; then
    gh label edit "$name" --color "$color" --description "$desc"
    echo "updated  $name"
  else
    gh label create "$name" --color "$color" --description "$desc"
    echo "created  $name"
  fi
}

create "agent:frontend" "1D76DB" "Next.js screens, components, RTL, design tokens, a11y"
create "agent:backend"  "0E8A16" "Server Actions, lib/data chokepoint, auth, access log"
create "agent:security" "B60205" "Security and privacy review — read-only, reports findings"
create "agent:database" "5319E7" "Schema, migrations, RLS policies, views, schema.test.sql"
create "agent:domain"   "FBCA04" "Pure engines — scheduling, risk, hebrew-calendar, templates"
create "agent:qa"       "006B75" "Tests across all four layers, CI harness"
create "agent:docs"     "C5DEF5" "SDD, PRD, ADRs, traceability"
create "agent:infra"    "5C5C5C" "Provisioning, deploys, env matrix, migration delivery"

echo
echo "Done. Attach one to a ticket with:  gh issue edit <n> --add-label agent:<name>"
