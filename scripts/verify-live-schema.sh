#!/usr/bin/env bash
# Verifies, by diff rather than by eye, that:
#   1. supabase/migrations/0001_init.sql is byte-identical to docs/schema.sql;
#   2. every local migration is applied on the linked Supabase project;
#   3. the linked project's schema matches the local migrations exactly,
#      apart from a short, documented allowlist of platform-owned objects
#      (requires Docker for the CLI's shadow database).
#
# Run after every `supabase db push`, against whichever project is currently
# linked. Exit 0 = verified. Exit 1 = mismatch. Exit 2 = only partially
# verified (no Docker) — do NOT tick the acceptance box on exit 2.
#
# Needs: pnpm install done; `pnpm exec supabase link --project-ref <ref>` run.
# docs/runbooks/migrations.md
#
# Self-test of the step-3 filter, no project or Docker needed:
#   bash scripts/verify-live-schema.sh --filter-diff < some-diff.sql
# prints what the allowlist absorbed and what remains; exits 1 if anything
# remains (i.e. genuine drift).
set -euo pipefail
cd "$(dirname "$0")/.."

# --------------------------------------------------------------------------
# Platform-object allowlist (#31).
#
# A hosted Supabase project injects objects into `public` that no migration
# creates and the CLI's shadow database does not have. They are owned by the
# platform's own role, so migrations neither can nor should manage them; the
# diff must ignore them without going blind to everything else.
#
# Each entry is a case-insensitive extended regex matched against the HEADER
# (first non-blank line) of one complete SQL statement of the diff, with
# dollar-quoted bodies kept inside their statement. Matching the header, not
# the whole text, is what keeps an entry about an object's own DDL from also
# absorbing some other function whose body merely mentions it. A statement
# is absorbed only if its header matches an entry; anything else is drift
# and fails step 3.
# Keep this list short and every entry justified — an entry that matches
# broadly (a schema, a role, a privilege keyword) would hide real drift.
#
#   1. public.rls_auto_enable() — Supabase's auto-RLS event-trigger function
#      (enables RLS on tables created through the dashboard). Owned by
#      supabase_admin. Seen live on pinkas-staging (#27). Matches its
#      CREATE/ALTER/COMMENT/GRANT/REVOKE statements and nothing else.
#   2. `set check_function_bodies = off;` — a session setting migra prints
#      before any function definition (here: entry 1's). Not a schema object.
#
# Deliberately NOT allowlisted: grants to anon, authenticated or
# service_role. 0005 states every one of those explicitly, so a privilege
# difference on our objects is drift worth failing for.
# --------------------------------------------------------------------------
RAE='"?public"?\."?rls_auto_enable"?[[:space:]]*\('
PLATFORM_ALLOWLIST=(
  "^(create([[:space:]]+or[[:space:]]+replace)?|alter|drop|comment[[:space:]]+on)[[:space:]]+function[[:space:]]+(if[[:space:]]+exists[[:space:]]+)?${RAE}"
  "^(grant|revoke)[[:space:]].*[[:space:]]on[[:space:]]+function[[:space:]]+${RAE}"
  '^set[[:space:]]+check_function_bodies[[:space:]]*=[[:space:]]*off[[:space:]]*;$'
)

# Splits SQL on stdin into statements (records separated by NUL), treating
# `;` inside a dollar-quoted body as part of the body. Line-based: migra ends
# every statement with `;` at end of line.
split_statements() {
  awk '
    BEGIN { inq = 0; tag = ""; buf = "" }
    {
      line = $0
      rest = line
      while (match(rest, /\$[A-Za-z_]*\$/)) {
        t = substr(rest, RSTART, RLENGTH)
        if (!inq) { inq = 1; tag = t }
        else if (t == tag) { inq = 0; tag = "" }
        rest = substr(rest, RSTART + RLENGTH)
      }
      buf = (buf == "" ? line : buf "\n" line)
      if (!inq && line ~ /;[[:space:]]*$/) { printf "%s%c", buf, 0; buf = "" }
    }
    END { if (buf ~ /[^[:space:]]/) printf "%s%c", buf, 0 }
  '
}

# Reads a diff on stdin. Prints absorbed and remaining statements; returns 1
# if any statement is not covered by the allowlist.
filter_diff() {
  local stmt header pattern matched drift=0 absorbed=0
  while IFS= read -r -d '' stmt; do
    [[ "$stmt" =~ [^[:space:]] ]] || continue
    header=$(printf '%s\n' "$stmt" | grep -m1 '[^[:space:]]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    matched=0
    for pattern in "${PLATFORM_ALLOWLIST[@]}"; do
      if printf '%s\n' "$header" | grep -Eqi -- "$pattern"; then matched=1; break; fi
    done
    if (( matched )); then
      absorbed=$((absorbed + 1))
      echo "allowlisted (platform-owned): $header"
    else
      drift=$((drift + 1))
      echo "DRIFT:"
      printf '%s\n' "$stmt"
    fi
  done < <(split_statements)
  echo "$absorbed statement(s) allowlisted, $drift statement(s) of drift"
  (( drift == 0 ))
}

if [[ "${1:-}" == "--filter-diff" ]]; then
  filter_diff
  exit $?
fi

# --------------------------------------------------------------------------
# What docs/schema.sql means (#31): the FROZEN INITIAL STATE.
#
# docs/schema.sql is the authoritative Phase 1 schema document and is, byte
# for byte, migration 0001. It is not edited to follow later migrations —
# 0002 onward are expand/contract deltas (docs/runbooks/migrations.md), and
# applied migrations are immutable, so a "current state" copy would be a
# second hand-maintained description that can drift from the first. The
# current schema is 0001 + every later migration in order, which is exactly
# what scripts/test-schema.sh builds and what steps 2 and 3 compare live.
# --------------------------------------------------------------------------
echo "== 1/3 docs/schema.sql vs 0001_init.sql (frozen initial state, byte diff) =="
if diff -u docs/schema.sql supabase/migrations/0001_init.sql; then
  echo "OK: 0001_init.sql is docs/schema.sql, unchanged"
  later=$(find supabase/migrations -maxdepth 1 -name '[0-9][0-9][0-9][0-9]_*.sql' ! -name '0001_*' | wc -l | tr -d ' ')
  echo "    $later later migration(s) are deltas on top of it; steps 2-3 verify them"
else
  echo "FAIL: 0001_init.sql has drifted from docs/schema.sql" >&2
  exit 1
fi

echo
echo "== 2/3 migrations applied on the linked project =="
pnpm exec supabase migration list --linked

echo
echo "== 3/3 live schema vs local migrations (supabase db diff, platform allowlist) =="
if ! docker info >/dev/null 2>&1; then
  echo "PARTIAL: Docker is not available, so 'supabase db diff --linked'" >&2
  echo "cannot run its shadow database. The applied schema was NOT verified" >&2
  echo "by diff. Re-run this script where Docker is available." >&2
  exit 2
fi

# stdout carries the SQL diff; the CLI's progress lines go to stderr and are
# kept out of the statements being judged.
errlog=$(mktemp)
trap 'rm -f "$errlog"' EXIT
if ! diff_sql=$(pnpm exec supabase db diff --linked --schema public 2>"$errlog"); then
  cat "$errlog" >&2
  echo "FAIL: supabase db diff errored" >&2
  exit 1
fi

if [[ ! "$diff_sql" =~ [^[:space:]] ]]; then
  echo "OK: linked project matches local migrations (no schema changes found)"
elif printf '%s\n' "$diff_sql" | filter_diff; then
  echo "OK: linked project matches local migrations, apart from allowlisted platform objects"
else
  echo "FAIL: the linked project's schema differs from the local migrations" >&2
  exit 1
fi
