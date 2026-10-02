#!/usr/bin/env bash
#
# Verifies the edge rate limit on /p/* against a REAL deployment (issue #40).
#
# A rate limit written in a dashboard is a claim. This script turns the three
# acceptance criteria that can be tested from outside into observed results:
#
#   1. Legitimate use is not caught. Sends the documented legitimate worst case
#      (docs/runbooks/portal-edge.md, "Thresholds") and requires zero 429s.
#   2. Abuse is caught. Bursts past the per-IP limit and requires a 429 within
#      the limit plus slack.
#   3. The limit does not reveal validity. Once limited, requests for different
#      tokens — and for a real one, if supplied — must get the same status and
#      content type, and the bodies are compared.
#
# Every request uses a fresh random 32-byte base64url token unless stated, so
# the probe never needs, and never prints, a real credential.
#
# Usage:   ./scripts/probe-portal-rate-limit.sh <base-url>
#   e.g.   ./scripts/probe-portal-rate-limit.sh https://<production-domain>
#
# Optional environment (read from the environment, never from argv, and never
# printed):
#   VERCEL_AUTOMATION_BYPASS_SECRET  only if probing a protected preview
#   PORTAL_PROBE_VALID_TOKEN         a STAGING bride's live portal token, for
#                                    check 3 against a token that resolves.
#                                    Never a production bride's token.
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

# request <token> <body-file> -> prints "status content-type"
# URL and bypass header go to curl through a config on stdin, so neither the
# token nor the secret appears in the process table.
request() {
  local token="$1" out="$2"
  {
    printf 'url = "%s/p/%s"\n' "$BASE" "$token"
    if [[ -n "${VERCEL_AUTOMATION_BYPASS_SECRET:-}" ]]; then
      printf 'header = "x-vercel-protection-bypass: %s"\n' "$VERCEL_AUTOMATION_BYPASS_SECRET"
    fi
  } | curl -sS -K - -o "$out" -w '%{http_code} %{content_type}\n' --max-time 15
}

# fetch <token> <body-file> -> sets STATUS and CTYPE. An unreachable host is
# an error, never a pass: "no 429 seen" means nothing if nothing was seen.
fetch() {
  local out
  out="$(request "$1" "$2")" || true
  STATUS="${out%% *}"
  CTYPE="${out#* }"
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
echo "1/3  legitimate envelope: 15 distinct links over 60s, then 5 rapid refreshes"
caught=0
for i in $(seq 1 15); do
  fetch "$(random_token)" /dev/null; status="$STATUS"
  [[ "$status" == "429" ]] && caught=$((caught + 1))
  sleep 4
done
bride="$(random_token)"
for i in $(seq 1 5); do
  fetch "$bride" /dev/null; status="$STATUS"
  [[ "$status" == "429" ]] && caught=$((caught + 1))
done
if [[ "$caught" -eq 0 ]]; then
  echo "     ok: 0 of 20 legitimate requests rate-limited (last status $status)"
else
  echo "     FAIL: $caught of 20 legitimate requests got 429 — the limit catches real use" >&2
  failed=1
fi

# ── 2. Burst past the limit ────────────────────────────────────────────────
echo "     waiting 65s for the one-minute window to reset"
sleep 65
echo "2/3  burst: up to $((LIMIT + SLACK)) rapid requests, expecting 429"
first_429=0
for i in $(seq 1 $((LIMIT + SLACK))); do
  fetch "$(random_token)" /dev/null; status="$STATUS"
  if [[ "$status" == "429" ]]; then
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
echo "3/3  while limited: compare responses for different tokens"
tok_a="$(random_token)"
tok_b="$(random_token)"
fetch "$tok_a" "$WORK/a"; s_a="$STATUS"; ct_a="$CTYPE"
fetch "$tok_b" "$WORK/b"; s_b="$STATUS"; ct_b="$CTYPE"
# The limited page is the host's, not ours. It must not echo the token back.
if grep -qF -e "$tok_a" "$WORK/a" || grep -qF -e "$tok_b" "$WORK/b"; then
  echo "     FAIL: the limited response echoes the token from the path." >&2
  failed=1
fi
summary="random A: $s_a, random B: $s_b"
statuses=("$s_a" "$s_b")
types=("$ct_a" "$ct_b")
bodies=("$WORK/a" "$WORK/b")
if [[ -n "${PORTAL_PROBE_VALID_TOKEN:-}" ]]; then
  fetch "$PORTAL_PROBE_VALID_TOKEN" "$WORK/v"; s_v="$STATUS"; ct_v="$CTYPE"
  summary="$summary, valid (staging): $s_v"
  statuses+=("$s_v"); types+=("$ct_v"); bodies+=("$WORK/v")
else
  echo "     note: PORTAL_PROBE_VALID_TOKEN not set — comparing two invalid tokens only."
  echo "           Re-run with a staging token once lib/data/portal.ts (#7) is deployed."
fi
echo "     $summary"
for i in "${!statuses[@]}"; do
  if [[ "${statuses[$i]}" != "429" ]]; then
    echo "     FAIL: a request was served while the IP should be limited — the" >&2
    echo "           limit is not applied uniformly across tokens." >&2
    failed=1
    break
  fi
  if [[ "${types[$i]}" != "${types[0]}" ]]; then
    echo "     FAIL: content type differs between tokens while limited." >&2
    failed=1
  fi
done
hashes="$(for b in "${bodies[@]}"; do sha256sum "$b" | cut -c1-16; done | sort -u | wc -l | tr -d ' ')"
if [[ "$hashes" -eq 1 ]]; then
  echo "     ok: limited response bodies are byte-identical across tokens"
else
  # Not an automatic failure: a host error page may embed a per-request ID.
  # A human must look at the difference and confirm it carries no validity
  # signal. The bodies are host error pages, not portal content.
  echo "     CHECK: limited bodies differ across tokens. Inspect before signing off:" >&2
  diff <(cat "${bodies[0]}") <(cat "${bodies[1]}") | head -20 >&2 || true
  failed=1
fi

if [[ "$failed" -ne 0 ]]; then
  echo "portal rate-limit probe: NOT verified — see above." >&2
  exit 1
fi
echo "portal rate-limit probe: verified against $BASE"
