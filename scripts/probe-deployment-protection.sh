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
# Checks the root and a portal path, because the portal path is the one that
# will one day read with the service-role key. Both must be refused without a
# Vercel login: 401 (Vercel Authentication) or 403. A 200, or a redirect that
# lands on the app itself, means the deployment is public.
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

probe_token="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
failed=0
echo "probe run at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
for base in "$@"; do
  base="${base%/}"
  for path in "/" "/today" "/p/$probe_token"; do
    # No -L: a protected deployment answers 401 itself; following redirects
    # could end on a login page that returns 200 and look like a pass.
    read -r status location < <(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
      --max-time 15 "$base$path" || echo 000)
    shown="$path"
    [[ "$path" == /p/* ]] && shown="/p/<random>"
    case "$status" in
      401|403) echo "ok    $status  $base$shown" ;;
      30[1278])
        # A redirect to Vercel's own login is protection; one to anywhere else
        # (including the app's own pages) is not.
        if [[ "$location" =~ ^https://(vercel\.com|[a-z0-9.-]+\.vercel\.com)/ ]]; then
          echo "ok    $status  $base$shown  -> Vercel login"
        else
          echo "FAIL  $status  $base$shown  -> ${location:-?}" >&2; failed=1
        fi
        ;;
      *)       echo "FAIL  $status  $base$shown  — reachable without Vercel login" >&2; failed=1 ;;
    esac
  done
done

if [[ "$failed" -ne 0 ]]; then
  echo "deployment protection: NOT in effect on at least one URL. Do not add" >&2
  echo "any environment variable to that scope until this passes." >&2
  exit 1
fi
echo "deployment protection: in effect on every URL probed."
