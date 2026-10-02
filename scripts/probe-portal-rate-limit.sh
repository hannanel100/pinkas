#!/usr/bin/env bash
#
# Verifies the edge rate limit on /p/* against a REAL deployment (issue #40).
#
# A rate limit written in a dashboard is a claim. This script turns the
# acceptance criteria that can be tested from outside into observed results:
#
#   1. Legitimate use is not caught. Sends the documented legitimate worst case
#      (docs/runbooks/portal-edge.md, "Thresholds") and requires zero 429s.
#   2. Abuse is caught. Bursts past the per-IP limit and requires a 429 within
#      the limit plus slack.
#   3. The limit does not reveal validity. Once limited, requests for different
#      tokens must get the same status and content type, identical bodies, and
#      no body may echo its token.
#   4. The rule cannot be sidestepped by spelling the path differently. While
#      limited, `//p/<t>` and `/%70/<t>` must be refused too, or not reach the
#      portal at all (404), or redirect into the limited `/p/` path.
#
# Every request uses a fresh random 32-byte base64url token, so the probe never
# needs, and never prints, a real credential.
#
# Usage:   ./scripts/probe-portal-rate-limit.sh <base-url>
#   e.g.   ./scripts/probe-portal-rate-limit.sh https://<production-domain>
#
# Optional environment (read from the environment, never from argv, and never
# printed). Enter secrets with `read -rs VAR; export VAR`, never `export VAR=…`:
#   VERCEL_AUTOMATION_BYPASS_SECRET  only if probing a protected preview
#   PORTAL_PROBE_VALID_TOKEN         a token that resolves in the environment
#                                    probed. No such environment exists today —
#                                    see portal-edge.md, checklist step 2 — and
#                                    it must never be a real bride's token.
#   PROBE_BURST_LIMIT                the per-minute limit configured (default 30)
#
# Side effect: the IP running this is rate-limited on /p/* for up to the longest
# window (10 minutes). Run it from an operator machine, not a shared network a
# bride might be on.
set -euo pipefail

BASE="${1:-}"
if [[ -z "$BASE" ]]; then
  echo "usage: $0 <base-url>" >&2
  exit 2
fi
BASE="${BASE%/}"
LIMIT="${PROBE_BURST_LIMIT:-30}"
SLACK=10

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

random_token() {
  head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'
}

# request <path> <body-file> -> prints "status redirect-url content-type"
# URL and bypass header go to curl through a config on stdin, so neither the
# token nor the secret appears in the process table. No -L: a redirect is
# reported, not followed.
request() {
  local path="$1" out="$2"
  {
    printf 'url = "%s%s"\n' "$BASE" "$path"
    if [[ -n "${VERCEL_AUTOMATION_BYPASS_SECRET:-}" ]]; then
      printf 'header = "x-vercel-protection-bypass: %s"\n' "$VERCEL_AUTOMATION_BYPASS_SECRET"
    fi
  } | curl -sS -K - --path-as-is -o "$out" \
      -w '%{http_code} %{redirect_url} %{content_type}\n' --max-time 15
}

# fetch <path> <body-file> -> sets STATUS, LOCATION and CTYPE. An unreachable
# host is an error, never a pass: "no 429 seen" means nothing if nothing was
# seen.
fetch() {
  local out rest
  out="$(request "$1" "$2")" || true
  STATUS="${out%% *}"
  rest="${out#* }"
  LOCATION="${rest%% *}"
  CTYPE="${rest#* }"
  if [[ -z "$STATUS" || "$STATUS" == "000" ]]; then
    echo "error: could not reach $BASE — nothing was verified." >&2
    exit 2
  fi
}

failed=0

# ── 1. Legitimate worst case ───────────────────────────────────────────────
# An instructor composing reminders for 15 brides in one minute (each wa.me
# compose makes WhatsApp fetch the link from HER phone for the preview), then a
# bride refreshing her own link 5 times in quick succession. 20 requests in
# about 65 seconds, from one IP.
echo "1/4  legitimate envelope: 15 distinct links over 60s, then 5 rapid refreshes"
caught=0
for i in $(seq 1 15); do
  fetch "/p/$(random_token)" /dev/null
  [[ "$STATUS" == "429" ]] && caught=$((caught + 1))
  sleep 4
done
bride="$(random_token)"
for i in $(seq 1 5); do
  fetch "/p/$bride" /dev/null
  [[ "$STATUS" == "429" ]] && caught=$((caught + 1))
done
if [[ "$caught" -eq 0 ]]; then
  echo "     ok: 0 of 20 legitimate requests rate-limited (last status $STATUS)"
else
  echo "     FAIL: $caught of 20 legitimate requests got 429 — the limit catches real use" >&2
  failed=1
fi

# ── 2. Burst past the limit ────────────────────────────────────────────────
echo "     waiting 65s for the one-minute window to reset"
sleep 65
echo "2/4  burst: up to $((LIMIT + SLACK)) rapid requests, expecting 429"
first_429=0
for i in $(seq 1 $((LIMIT + SLACK))); do
  fetch "/p/$(random_token)" /dev/null
  if [[ "$STATUS" == "429" ]]; then
    first_429="$i"
    break
  fi
done
if [[ "$first_429" -gt 0 ]]; then
  echo "     ok: first 429 at request $first_429 (configured limit $LIMIT/min)"
else
  echo "     FAIL: no 429 after $((LIMIT + SLACK)) requests — the limit is not active" >&2
  failed=1
fi

# ── 3. Limited responses are indistinguishable ─────────────────────────────
echo "3/4  while limited: compare responses for different tokens"
tokens=("$(random_token)" "$(random_token)")
labels=("random A" "random B")
if [[ -n "${PORTAL_PROBE_VALID_TOKEN:-}" ]]; then
  tokens+=("$PORTAL_PROBE_VALID_TOKEN")
  labels+=("valid")
else
  echo "     note: PORTAL_PROBE_VALID_TOKEN not set — comparing two invalid tokens."
  echo "           The edge decides on IP alone, so this covers the edge (portal-edge.md)."
fi
summary=""
for i in "${!tokens[@]}"; do
  fetch "/p/${tokens[$i]}" "$WORK/body$i"
  statuses[$i]="$STATUS"
  types[$i]="$CTYPE"
  summary="$summary${summary:+, }${labels[$i]}: $STATUS"
  # The limited page is the host's, not ours. It must not echo the token —
  # for the valid token above all.
  if grep -qF -e "${tokens[$i]}" "$WORK/body$i"; then
    echo "     FAIL: the response for ${labels[$i]} echoes its token from the path." >&2
    failed=1
  fi
done
echo "     $summary"
for i in "${!statuses[@]}"; do
  if [[ "${statuses[$i]}" != "429" ]]; then
    echo "     FAIL: ${labels[$i]} was served while the IP should be limited — the" >&2
    echo "           limit is not applied uniformly across tokens." >&2
    failed=1
  fi
  if [[ "${types[$i]}" != "${types[0]}" ]]; then
    echo "     FAIL: content type differs between tokens while limited." >&2
    failed=1
  fi
done
hashes="$(for i in "${!tokens[@]}"; do sha256sum "$WORK/body$i" | cut -c1-16; done | sort -u | wc -l | tr -d ' ')"
if [[ "$hashes" -eq 1 ]]; then
  echo "     ok: limited response bodies are byte-identical across tokens"
else
  # Not automatically a validity leak: a host error page may embed a
  # per-request ID. A human must confirm the difference carries no signal.
  # Only the two RANDOM-token bodies are ever printed.
  echo "     CHECK: limited bodies differ across tokens. Inspect before signing off" >&2
  echo "            (random A vs random B shown; the valid one is never printed):" >&2
  diff "$WORK/body0" "$WORK/body1" | head -20 >&2 || true
  failed=1
fi

# ── 4. Path spellings that might dodge a "starts with /p/" rule ────────────
echo "4/4  while limited: alternative spellings of the portal path"
for variant in "//p/" "/%70/" "/P/"; do
  fetch "$variant$(random_token)" /dev/null
  case "$STATUS" in
    429) echo "     ok: ${variant}<t> -> 429 (covered by the rule)" ;;
    404) echo "     ok: ${variant}<t> -> 404 (does not reach the portal)" ;;
    30[1278])
      if [[ "$LOCATION" == "$BASE/p/"* || "$LOCATION" == /p/* ]]; then
        echo "     ok: ${variant}<t> -> $STATUS into /p/ (the limited path)"
      else
        echo "     FAIL: ${variant}<t> -> $STATUS to an unexpected location" >&2
        failed=1
      fi
      ;;
    *)
      echo "     FAIL: ${variant}<t> -> $STATUS while limited — this spelling may reach" >&2
      echo "           the portal without passing the rate-limit rule. Inspect." >&2
      failed=1
      ;;
  esac
done

if [[ "$failed" -ne 0 ]]; then
  echo "portal rate-limit probe: NOT verified — see above." >&2
  exit 1
fi
echo "portal rate-limit probe: verified against $BASE"
