#!/usr/bin/env bash
# cors-check.sh — verify CORS for a route the testbench will call.
# In v10, CORS is applied centrally: the app echoes the request Origin as
# Access-Control-Allow-Origin ONLY if it matches config:origin-whitelist (localhost by default).
# So the DEFAULT origin here is the LOCAL testbench (http://localhost:3000), which is whitelisted.
# Usage: cors-check.sh ENDPOINT_URL [ORIGIN] [METHOD]
#   ENDPOINT_URL e.g. http://localhost:8080/exist/apps/<abbrev>/api/reconcile
#   ORIGIN       default http://localhost:3000 (local testbench). Try the hosted origin only if you
#                deliberately widened the whitelist: https://reconciliation-api.github.io
#   METHOD       default POST
set -euo pipefail
URL="${1:?usage: cors-check.sh ENDPOINT_URL [ORIGIN] [METHOD]}"
ORIGIN="${2:-http://localhost:3000}"
METHOD="${3:-POST}"
fail=0

echo "== OPTIONS preflight (Origin: ${ORIGIN}) =="
pre="$(curl -s -D - -o /dev/null -X OPTIONS "${URL}" \
  -H "Origin: ${ORIGIN}" \
  -H "Access-Control-Request-Method: ${METHOD}" \
  -H "Access-Control-Request-Headers: content-type")"
echo "${pre}"

check() { # header  regex
  if printf '%s' "${pre}" | grep -i "^$1:" | grep -iqE "$2"; then
    echo "  OK   $1 satisfies /$2/"
  else
    echo "  FAIL $1 missing or doesn't match /$2/"; fail=1
  fi
}
check 'Access-Control-Allow-Origin'  "(\\*|${ORIGIN//\//\\/})"
check 'Access-Control-Allow-Methods' "${METHOD}"
check 'Access-Control-Allow-Headers' "content-type"

echo
echo "== Real ${METHOD} (Origin: ${ORIGIN}) =="
real="$(curl -s -D - -o /dev/null -X "${METHOD}" "${URL}" -H "Origin: ${ORIGIN}" \
  ${BODY:+--data "${BODY}"} ${CONTENT_TYPE:+-H "Content-Type: ${CONTENT_TYPE}"})"
echo "${real}"
if printf '%s' "${real}" | grep -i '^Access-Control-Allow-Origin:' \
     | grep -iqE "(\\*|${ORIGIN//\//\\/})"; then
  echo "  OK   response echoes Access-Control-Allow-Origin"
else
  echo "  FAIL no Access-Control-Allow-Origin — origin not whitelisted (browser will block the body)"
  echo "       Fix: use a localhost testbench, or add this origin to config:origin-whitelist."
  fail=1
fi
exit "${fail}"
