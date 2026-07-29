#!/usr/bin/env bash
#
# Runs the isolation and risk-tier suite against a real Postgres.
#
# SDD §17.1: "Non-zero exit means the isolation design regressed. This belongs
# in CI from the first commit." A green run asserts, among other things, that a
# tenant cannot read another tenant's brides even by primary key, that
# `private_note` never crosses tenants, that both views respect the caller's
# RLS, that `access_log` cannot be deleted, and that `portal_session_view`
# exposes exactly the seven permitted columns.
#
# Usage:  ./scripts/test-schema.sh [database-url]
set -euo pipefail

DB_URL="${1:-${DATABASE_URL:-}}"
DB_NAME="pinkas_test"
CREATED_DB=0

cd "$(dirname "$0")/.."

if [[ -z "$DB_URL" ]]; then
  # No URL given — create a throwaway local database, as the SDD documents.
  if ! command -v createdb >/dev/null 2>&1; then
    echo "error: no DATABASE_URL and createdb not on PATH." >&2
    echo "       Install Postgres client tools, or pass a connection URL." >&2
    exit 1
  fi
  dropdb --if-exists "$DB_NAME"
  createdb "$DB_NAME"
  CREATED_DB=1
  DB_URL="$DB_NAME"
fi

cleanup() {
  if [[ "$CREATED_DB" -eq 1 ]]; then
    dropdb --if-exists "$DB_NAME" || true
  fi
}
trap cleanup EXIT

# The migration must stay byte-identical to the authoritative schema — CLAUDE.md
# says schema.sql "becomes supabase/migrations/0001_init.sql unchanged". Drift
# here would mean the thing under test is not the thing that ships.
if ! cmp -s docs/schema.sql supabase/migrations/0001_init.sql; then
  echo "error: supabase/migrations/0001_init.sql has drifted from docs/schema.sql." >&2
  echo "       They must be identical. Re-copy, or change both deliberately." >&2
  diff -u docs/schema.sql supabase/migrations/0001_init.sql >&2 || true
  exit 1
fi

psql -d "$DB_URL" -v ON_ERROR_STOP=1 \
  -f docs/schema.bootstrap.sql \
  -f docs/schema.sql \
  -f docs/schema.test.sql

echo "schema suite passed"
