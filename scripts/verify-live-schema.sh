#!/usr/bin/env bash
# Verifies, by diff rather than by eye, that:
#   1. supabase/migrations/0001_init.sql is byte-identical to docs/schema.sql
#      (the migration is the schema document, unchanged — CLAUDE.md);
#   2. every local migration is applied on the linked Supabase project;
#   3. the linked project's schema matches the local migrations exactly
#      (requires Docker for the CLI's shadow database).
#
# Run after every `supabase db push`, against whichever project is currently
# linked. Exit 0 = verified. Exit 1 = mismatch. Exit 2 = only partially
# verified (no Docker) — do NOT tick the acceptance box on exit 2.
#
# Needs: pnpm install done; `pnpm exec supabase link --project-ref <ref>` run.
# docs/runbooks/migrations.md
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== 1/3 migration file vs docs/schema.sql (byte diff) =="
if diff -u docs/schema.sql supabase/migrations/0001_init.sql; then
  echo "OK: 0001_init.sql is docs/schema.sql, unchanged"
else
  echo "FAIL: 0001_init.sql has drifted from docs/schema.sql" >&2
  exit 1
fi

echo
echo "== 2/3 migrations applied on the linked project =="
pnpm exec supabase migration list --linked

echo
echo "== 3/3 live schema vs local migrations (supabase db diff) =="
if ! docker info >/dev/null 2>&1; then
  echo "PARTIAL: Docker is not available, so 'supabase db diff --linked'" >&2
  echo "cannot run its shadow database. The applied schema was NOT verified" >&2
  echo "by diff. Re-run this script where Docker is available." >&2
  exit 2
fi

out=$(pnpm exec supabase db diff --linked --schema public 2>&1) || {
  echo "$out" >&2
  echo "FAIL: supabase db diff errored" >&2
  exit 1
}
if echo "$out" | grep -qi "no schema changes found"; then
  echo "OK: linked project matches local migrations (no schema changes found)"
else
  echo "$out"
  echo "FAIL: the linked project's schema differs from the local migrations" >&2
  exit 1
fi
