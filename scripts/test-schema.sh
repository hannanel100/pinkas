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
# The database under test is built from `supabase/migrations/`, applied in
# order — the same files, in the same sequence, that every real environment has
# run. Feeding Postgres `docs/schema.sql` instead would verify a schema frozen
# at the first migration.
#
# Usage:  ./scripts/test-schema.sh [database-url]
#
# Opt-in: SCHEMA_TEST_AS_MIGRATOR=1 applies the migrations as a NON-superuser
# role shaped like Supabase's `postgres` (CREATEROLE, BYPASSRLS, owns the
# database; see docs/schema.bootstrap.migrator.sql). A superuser skips every
# ownership, membership and schema-privilege check, so a migration can pass
# the default run and still fail on the live platform — 0006 did (PR #51).
# The assertions themselves still run as superuser, as in the default run.
# The role is cluster-wide: use a throwaway cluster or database server.
set -euo pipefail

DB_URL="${1:-${DATABASE_URL:-}}"
DB_NAME="pinkas_test"
CREATED_DB=0
MIGRATION_DIR="supabase/migrations"

cd "$(dirname "$0")/.."

if [[ -z "$DB_URL" ]]; then
  # No URL given — create a throwaway local database, as the SDD documents.
  if ! command -v createdb >/dev/null 2>&1; then
    echo "error: no DATABASE_URL and createdb not on PATH." >&2
    echo "       Install Postgres client tools, or pass a connection URL:" >&2
    echo "       ./scripts/test-schema.sh postgresql://user:pass@host:5432/db" >&2
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

# --------------------------------------------------------------------------
# Drift check — this is NOT how the schema is loaded.
#
# The two roles are easy to confuse when reading this script later. The
# database below is built from supabase/migrations/, 0001_init.sql included,
# applied like any other migration. The check here is a separate assertion:
# docs/schema.sql is the authoritative document and CLAUDE.md says it "becomes
# supabase/migrations/0001_init.sql unchanged", so the two must stay
# byte-identical. It keeps the document honest. It does not feed Postgres.
# --------------------------------------------------------------------------
if ! cmp -s docs/schema.sql "$MIGRATION_DIR/0001_init.sql"; then
  echo "error: $MIGRATION_DIR/0001_init.sql has drifted from docs/schema.sql." >&2
  echo "       They must be identical. Re-copy, or change both deliberately." >&2
  diff -u docs/schema.sql "$MIGRATION_DIR/0001_init.sql" >&2 || true
  exit 1
fi

# --------------------------------------------------------------------------
# Enumerate the migrations, in a defined order.
#
# The order is the four-digit prefix, sorted numerically. The zero padding is a
# convention this script enforces rather than assumes: `10_late.sql` sorts
# before `0002_early.sql` lexically, so a name that is not exactly
# NNNN_lower_snake_name.sql is rejected here instead of being applied in the
# wrong place or skipped. The numbers must run 0001, 0002, 0003 … with no gap
# and no duplicate — a gap means a migration file is missing from the checkout,
# a duplicate means two branches picked the same number. Either way the harness
# would be testing a schema no environment has, so it fails loudly rather than
# reporting green.
# --------------------------------------------------------------------------
shopt -s nullglob dotglob
entries=("$MIGRATION_DIR"/*)
shopt -u nullglob dotglob

if [[ ${#entries[@]} -eq 0 ]]; then
  echo "error: $MIGRATION_DIR is empty — there is no schema to test." >&2
  exit 1
fi

numbered=()
for path in "${entries[@]}"; do
  name="${path##*/}"
  if [[ ! -f "$path" ]] || [[ ! "$name" =~ ^([0-9]{4})_[a-z0-9_]+\.sql$ ]]; then
    echo "error: $path is not a migration this harness can order." >&2
    echo "       Every entry in $MIGRATION_DIR must be a file named" >&2
    echo "       NNNN_lower_snake_name.sql with a four-digit, zero-padded" >&2
    echo "       number — for example 0002_add_message_status.sql." >&2
    exit 1
  fi
  numbered+=("${BASH_REMATCH[1]}"$'\t'"$path")
done

migrations=()
expected=1
while IFS=$'\t' read -r num path; do
  n=$((10#$num))
  if (( n < expected )); then
    echo "error: migration number $num is used more than once in $MIGRATION_DIR." >&2
    echo "       Two branches picked the same number; renumber one of them." >&2
    exit 1
  fi
  if (( n > expected )); then
    echo "error: migration numbers jump from $((expected - 1)) to $n in $MIGRATION_DIR." >&2
    echo "       A gap means a migration file is missing from this checkout, so" >&2
    echo "       the schema under test is not the schema that ships." >&2
    exit 1
  fi
  migrations+=("$path")
  expected=$((n + 1))
done < <(printf '%s\n' "${numbered[@]}" | sort -t$'\t' -k1,1n)

echo "applying ${#migrations[@]} migration(s):"
printf '  %s\n' "${migrations[@]}"

# One psql session: the bootstrap (Supabase's auth.uid() and roles), then every
# migration in order, then the assertions.
psql_args=(-d "$DB_URL" -v ON_ERROR_STOP=1 -f docs/schema.bootstrap.sql)
if [[ "${SCHEMA_TEST_AS_MIGRATOR:-0}" == "1" ]]; then
  echo "migration role: pinkas_migrator (non-superuser, SCHEMA_TEST_AS_MIGRATOR=1)"
  psql_args+=(-f docs/schema.bootstrap.migrator.sql)
fi
# Non-vacuity guard (#53). From 0008 on, the migrations revoke every default
# privilege the bootstrap emulates, so nothing in the finished database shows
# whether the emulation ever ran — and without it, "a new table grants
# nothing to service_role / anon / authenticated" would pass on any plain
# Postgres. Assert it here, as the migration role, before the first migration.
psql_args+=(-c "do \$\$ begin
  if not exists (
    select 1 from pg_default_acl d, aclexplode(d.defaclacl) a
    where d.defaclrole = current_user::regrole
      and d.defaclnamespace = 'public'::regnamespace
      and d.defaclobjtype = 'r'
      and a.grantee = 'service_role'::regrole
      and a.privilege_type = 'SELECT')
  then
    raise exception 'FAIL: the bootstrap does not emulate Supabase''s default privileges for the migration role';
  end if;
end \$\$")
for path in "${migrations[@]}"; do
  psql_args+=(-f "$path")
done
psql_args+=(-c "reset role" -f docs/schema.test.sql)

psql "${psql_args[@]}"

# --------------------------------------------------------------------------
# Negative scenario (security review of #61): 0008 must REFUSE to adopt a
# pre-existing portal_owner / portal_reader that has a member — e.g. one an
# operator granted to `authenticated`, through which a tenant would read
# every tenant's brides via the `to portal_owner` policies. The suite above
# can only see the state after a successful apply, so this applies the
# migrations again into a scratch database on the same server (roles are
# cluster-wide, so the portal roles already exist), grants the role to
# `authenticated`, and expects 0008 to fail with the refusal. Applied as the
# connecting role in both modes; the guard does not depend on which.
# --------------------------------------------------------------------------
adopt_db="pinkas_adopt53"
pre_0008=()
mig_0008=""
for path in "${migrations[@]}"; do
  name="${path##*/}"
  if [[ "$name" == 0008_* ]]; then mig_0008="$path"; break; fi
  pre_0008+=(-f "$path")
done
if [[ -n "$mig_0008" ]]; then
  adopt_cleanup() {
    psql -d "$DB_URL" -q -X \
      -c "revoke portal_owner from authenticated" \
      -c "revoke portal_reader from authenticated" \
      -c "drop database if exists $adopt_db" >/dev/null 2>&1 || true
  }
  for portal in portal_owner portal_reader; do
    adopt_cleanup
    psql -d "$DB_URL" -q -X -v ON_ERROR_STOP=1 -c "create database $adopt_db" >/dev/null
    if out=$(psql -d "$DB_URL" -X -v ON_ERROR_STOP=1 -c "\\c $adopt_db" \
                -f docs/schema.bootstrap.sql "${pre_0008[@]}" \
                -c "grant $portal to authenticated" \
                -f "$mig_0008" 2>&1); then
      adopt_cleanup
      echo "FAIL: 0008 adopted a pre-existing $portal that has a member (authenticated)" >&2
      exit 1
    fi
    if [[ "$out" != *"$portal exists and has members"* ]]; then
      adopt_cleanup
      printf '%s\n' "$out" | tail -5 >&2
      echo "FAIL: 0008 failed, but not with the adoption refusal for $portal" >&2
      exit 1
    fi
    echo "PASS: 0008 refuses to adopt a $portal that has a member"
  done
  adopt_cleanup
fi

echo "schema suite passed"
