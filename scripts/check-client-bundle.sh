#!/usr/bin/env bash
#
# Proves that no server-only secret reached anything a browser can download.
#
# Issue #28: "SUPABASE_SERVICE_ROLE_KEY is confirmed absent from every client
# bundle by searching the build output — the NEXT_PUBLIC_ discipline is the
# guard, not the proof." This script is the proof. Run it after `next build`.
#
# What a browser can fetch from a Next.js deployment, and so what is scanned:
#   .next/static/          every client chunk, CSS file and build manifest
#   .next/server/app/      only the prerendered artefacts served verbatim:
#   .next/server/pages/      *.html, *.rsc, *.body, *.meta
#   public/                served as-is
# Server chunks (*.js under .next/server) are deliberately NOT scanned: they
# never leave the function, and Next.js does not inline non-NEXT_PUBLIC_ values
# into them — they read process.env at runtime.
#
# Three checks, from strongest to weakest:
#
#   1. The actual value. If a secret variable is set in the build environment
#      (it is, on every Vercel build of a scope that holds it), its exact value
#      is searched for. The value is handed to grep through a file descriptor,
#      never on a command line, and is never printed — a match reports the file
#      and the variable NAME only.
#   2. Shape. A Supabase service-role JWT carries "role":"service_role" in its
#      payload; its base64url encoding is matched at all three byte alignments.
#      Newer Supabase secret keys are `sb_secret_` plus key material (the bare
#      prefix is not matched: supabase-js itself contains it as a string
#      literal, and a check that cries wolf gets deleted). This catches a key
#      from a *different* project or scope than the one being built.
#   3. The variable name. Client code that mentions process.env.SUPABASE_SERVICE_
#      ROLE_KEY evaluates to undefined in the browser, so nothing leaks — but it
#      means a module meant for the server was bundled for the client, which is
#      the bug one refactor away from a leak. Treated as a failure.
#
# Exit 0: clean. Exit 1: a finding (the build must not ship). Exit 2: usage
# error or no build output to scan — absence of evidence is not a pass.
#
# Usage:  ./scripts/check-client-bundle.sh [project-root]
#
# Adding a variable: append its name to SECRET_VARS. #39 adds the anon key here
# once it stops being NEXT_PUBLIC_.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

SECRET_VARS=(SUPABASE_SERVICE_ROLE_KEY)

# Extended regexes. The first three are base64url of `service_role` at byte
# offsets 0, 1 and 2, trimmed to the characters that do not depend on the
# neighbouring bytes. Derivation:
#   offset 0: base64("service_role")         -> c2VydmljZV9yb2xl
#   offset 1: base64("\0service_role")[2:14] -> NlcnZpY2Vfcm9s
#   offset 2: base64("\0\0service_role")[3:13] -> zZXJ2aWNlX3Jv
SHAPE_PATTERNS=(
  'c2VydmljZV9yb2xl'
  'NlcnZpY2Vfcm9s'
  'zZXJ2aWNlX3Jv'
  'sb_secret_[A-Za-z0-9_-]{20,}'
)

if [[ ! -d .next/static ]]; then
  echo "error: .next/static not found under $ROOT — run \`next build\` first." >&2
  echo "       Nothing scanned is not the same as nothing found." >&2
  exit 2
fi

# Collect the browser-reachable files once, NUL-separated.
targets="$(mktemp)"
trap 'rm -f "$targets"' EXIT
{
  find .next/static -type f -print0
  for dir in .next/server/app .next/server/pages; do
    [[ -d "$dir" ]] && find "$dir" -type f \
      \( -name '*.html' -o -name '*.rsc' -o -name '*.body' -o -name '*.meta' \) -print0
  done
  [[ -d public ]] && find public -type f -print0
} >"$targets"

count="$(tr -cd '\0' <"$targets" | wc -c | tr -d ' ')"
if [[ "$count" -eq 0 ]]; then
  echo "error: no browser-reachable build files found to scan." >&2
  exit 2
fi

failed=0

# grep over the target list; prints matching file names only (-l), never lines.
scan() {
  xargs -0 grep -l "$@" -- <"$targets" 2>/dev/null || true
}

# 1. Exact values, when present in this build's environment.
for var in "${SECRET_VARS[@]}"; do
  value="${!var:-}"
  if [[ -z "$value" ]]; then
    echo "note: $var is not set in this build's environment — value check skipped for it."
    continue
  fi
  if (( ${#value} < 20 )); then
    # Too short to be a real key; matching it would be noise, not proof.
    echo "error: $var is set but implausibly short; refusing to treat it as a key." >&2
    exit 2
  fi
  # printf is a shell builtin: the value goes through a pipe, not argv, so it
  # does not appear in the process table.
  hits="$(scan -F -f <(printf '%s\n' "$value"))"
  if [[ -n "$hits" ]]; then
    echo "FAIL: the value of $var appears in browser-reachable build output:" >&2
    sed 's/^/  /' <<<"$hits" >&2
    failed=1
  else
    echo "ok: value of $var absent from $count browser-reachable files."
  fi
done
unset value

# 2. Shape of a service-role credential, from any project.
shape_clean=1
for pattern in "${SHAPE_PATTERNS[@]}"; do
  hits="$(scan -E -e "$pattern")"
  if [[ -n "$hits" ]]; then
    echo "FAIL: a service-role-shaped credential ($pattern) appears in:" >&2
    sed 's/^/  /' <<<"$hits" >&2
    failed=1
    shape_clean=0
  fi
done
[[ "$shape_clean" -eq 1 ]] && echo "ok: no service-role-shaped credential in browser-reachable output."

# 3. The variable name: a server module bundled for the client.
for var in "${SECRET_VARS[@]}"; do
  hits="$(scan -F -e "$var")"
  if [[ -n "$hits" ]]; then
    echo "FAIL: $var is referenced in client output — a server-only module was" >&2
    echo "      bundled for the browser. It reads undefined there today; fix the" >&2
    echo "      import graph before it reads something else:" >&2
    sed 's/^/  /' <<<"$hits" >&2
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "client bundle check FAILED — do not ship this build (invariant 5, PRD §10.1)." >&2
  exit 1
fi
echo "client bundle check passed."
