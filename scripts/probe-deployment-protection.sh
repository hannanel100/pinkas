#!/usr/bin/env bash
#
# Proves a Vercel deployment URL is NOT publicly readable (issue #28).
#
# "Deployment Protection was enabled before the first Supabase environment
# variable was set — verifiable, not asserted from memory." Run this against a
# preview URL BEFORE adding any variable to the preview scope, and paste the
# output (it contains no secret) into the ticket. Its timestamp, next to the
# variables' creation times, is the ordering evidence.
#
# Checks the root, an instructor route and a portal path. Each must be refused
# BY VERCEL'S AUTHENTICATION LAYER, not merely with some 401/403: the status
# alone would also pass if the app itself (or anything else in front of it)
# happened to answer 401. So a refusal counts only when it also carries
# Vercel's SSO marker — a `server: Vercel` header plus either the
# `_vercel_sso_nonce` cookie or a reference to Vercel's SSO endpoint in the
# body. A redirect counts only if it goes to vercel.com.
#
# Usage:  ./scripts/probe-deployment-protection.sh <deployment-url> [...]
#
# For the production domain the expected result is the opposite — it is public
# by design (instructors and brides must reach it). Do not run this against it
# expecting a pass.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <deployment-url> [...]" >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

probe_token="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
failed=0
echo "probe run at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
for base in "$@"; do
  base="${base%/}"
  for path in "/" "/today" "/p/$probe_token"; do
    shown="$path"
    [[ "$path" == /p/* ]] && shown="/p/<random>"
    # No -L: a protected deployment answers 401 itself; following redirects
    # could end on a login page that returns 200 and look like a pass.
    out="$(curl -sS -D "$work/headers" -o "$work/body" \
      -w '%{http_code} %{redirect_url}' --max-time 15 "$base$path" || echo 000)"
    status="${out%% *}"
    location="${out#* }"
    [[ "$location" == "$out" ]] && location=""
    case "$status" in
      401|403)
        is_vercel=0; has_sso=0
        grep -qi '^server: *vercel' "$work/headers" 2>/dev/null && is_vercel=1
        if grep -qi '^set-cookie: *_vercel_sso_nonce=' "$work/headers" 2>/dev/null \
          || grep -qi 'sso-api' "$work/body" 2>/dev/null; then
          has_sso=1
        fi
        if ((is_vercel && has_sso)); then
          echo "ok    $status  $base$shown  (Vercel SSO)"
        else
          echo "FAIL  $status  $base$shown  — refused, but without Vercel's SSO marker" >&2
          echo "      (server: Vercel=$is_vercel, SSO cookie/endpoint=$has_sso). Something" >&2
          echo "      other than Deployment Protection answered; inspect before trusting it." >&2
          failed=1
        fi
        ;;
      30[1278])
        # A redirect to Vercel's own login is protection; one to anywhere else
        # (including the app's own pages) is not.
        if [[ "$location" =~ ^https://(vercel\.com|[a-z0-9.-]+\.vercel\.com)/ ]]; then
          echo "ok    $status  $base$shown  -> Vercel login"
        else
          echo "FAIL  $status  $base$shown  -> ${location:-?}" >&2; failed=1
        fi
        ;;
      *) echo "FAIL  $status  $base$shown  — reachable without Vercel login" >&2; failed=1 ;;
    esac
  done
done

if [[ "$failed" -ne 0 ]]; then
  echo "deployment protection: NOT proven on at least one URL. Do not add" >&2
  echo "any environment variable to that scope until this passes." >&2
  exit 1
fi
echo "deployment protection: in effect on every URL probed."
