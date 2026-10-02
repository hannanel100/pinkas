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
# remains (genuine drift) or if the input held no statement at all.
set -euo pipefail
cd "$(dirname "$0")/.."

# --------------------------------------------------------------------------
# Platform-object allowlist (#31; tightened after the PR #51 review).
#
# A hosted Supabase project injects objects into `public` that no migration
# creates and the CLI's shadow database does not have. They are owned by the
# platform's own role, so migrations neither can nor should manage them; the
# diff must ignore them without going blind to everything else.
#
# The diff is split into complete SQL statements (dollar-quoted bodies kept
# inside their statement). A statement is absorbed only if the WHOLE
# statement has an expected, exact shape — never because it merely mentions
# a platform object. Two kinds of entry:
#
#   PLATFORM_EXACT  — case-insensitive extended regexes that must match the
#                     whole statement, which must be a single line.
#   PLATFORM_PINNED — SHA-256 of a whole multi-line statement (leading blank
#                     lines dropped, trailing whitespace stripped per line).
#                     Used where the statement carries a body: any change to
#                     the body, signature, return type or options changes it.
#
# Entries, all for public.rls_auto_enable() — Supabase's auto-RLS
# event-trigger function, owned by supabase_admin, seen on pinkas-staging (#27):
#   1. Its CREATE OR REPLACE FUNCTION, pinned by hash. The list starts EMPTY
#      on purpose: nobody has captured the live statement yet. On the first
#      run step 3 fails and prints the statement with its hash, labelled an
#      unpinned candidate; a human compares it with Supabase's published
#      definition and, if it matches, pins the hash here in a reviewed
#      commit. Any later change to it is drift until re-pinned.
#   2. GRANT/REVOKE EXECUTE on exactly `"public"."rls_auto_enable"()` to/from
#      exactly one platform role — the platform's own default ACL on its own
#      function. It is an event-trigger function: not callable.
#   3. `set check_function_bodies = off;` — the session setting migra prints
#      before any function definition. Not a schema object.
#
# Not absorbed, deliberately: ALTER (including OWNER TO), DROP or COMMENT on
# it; any other overload; any other function; any grant on our objects —
# 0005 states every one of those explicitly, so a difference is drift.
# Adding an entry is a reviewed change (docs/runbooks/migrations.md).
# --------------------------------------------------------------------------
PLATFORM_EXACT=(
  '(grant|revoke) execute on function "public"\."rls_auto_enable"\(\) (to|from) "(anon|authenticated|service_role|postgres)";'
  'set check_function_bodies = off;'
)
PLATFORM_PINNED=(
  # sha256 of the live `CREATE OR REPLACE FUNCTION public.rls_auto_enable()`
  # statement, pinned after the first reviewed capture (see entry 1).
)
# Recognises a statement that is ABOUT the platform function, only to label
# an unpinned one helpfully. It never absorbs anything.
PLATFORM_CANDIDATE='^create or replace function public\.rls_auto_enable\(\)$'

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

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

# Reads a diff on stdin. Prints absorbed and remaining statements. Returns 0
# only if every statement was absorbed AND there was at least one: an empty
# diff is judged by the CLI's own "no schema changes" marker, not here.
filter_diff() {
  local stmt norm header hash pattern pin matched drift=0 absorbed=0
  while IFS= read -r -d '' stmt; do
    [[ "$stmt" =~ [^[:space:]] ]] || continue
    norm=$(printf '%s\n' "$stmt" | sed -E 's/[[:space:]]+$//' | sed '/./,$!d')
    header=$(printf '%s\n' "$norm" | head -n 1)
    hash=$(printf '%s\n' "$norm" | sha256_stdin)
    matched=0
    if [[ "$norm" != *$'\n'* ]]; then
      for pattern in "${PLATFORM_EXACT[@]}"; do
        if printf '%s\n' "$norm" | grep -Eqix -- "$pattern"; then matched=1; break; fi
      done
    fi
    for pin in "${PLATFORM_PINNED[@]+"${PLATFORM_PINNED[@]}"}"; do
      if [[ "$hash" == "$pin" ]]; then matched=1; fi
    done
    if (( matched )); then
      absorbed=$((absorbed + 1))
      echo "allowlisted (platform-owned): $header"
    else
      drift=$((drift + 1))
      if printf '%s\n' "$header" | grep -Eqi -- "$PLATFORM_CANDIDATE"; then
        echo "DRIFT (unpinned platform candidate, sha256 $hash - verify against Supabase's definition before pinning):"
      else
        echo "DRIFT:"
      fi
      printf '%s\n' "$norm"
    fi
  done < <(split_statements)
  echo "$absorbed statement(s) allowlisted, $drift statement(s) of drift"
  (( drift == 0 && absorbed > 0 ))
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

# Clean means the CLI SAID so. Empty stdout alone is not evidence: a CLI
# change, a redirected stream or a silent failure would produce it too.
if [[ ! "$diff_sql" =~ [^[:space:]] ]]; then
  if grep -qi "no schema changes found" "$errlog" || printf '%s\n' "$diff_sql" | grep -qi "no schema changes found"; then
    echo "OK: linked project matches local migrations (CLI: no schema changes found)"
  else
    cat "$errlog" >&2
    echo "FAIL: supabase db diff printed no SQL and no 'No schema changes found'" >&2
    echo "      marker; a clean diff cannot be told from a broken one." >&2
    exit 1
  fi
elif printf '%s\n' "$diff_sql" | filter_diff; then
  echo "OK: linked project matches local migrations, apart from allowlisted platform objects"
else
  echo "FAIL: the linked project's schema differs from the local migrations" >&2
  exit 1
fi
