#!/usr/bin/env bash
# ad-hoc-xquery.sh — run an XQuery snippet directly in eXist (layer-1 logic check).
# Reads the query from a file arg or stdin, POSTs it in eXist's <query> envelope.
# Usage:
#   ad-hoc-xquery.sh path/to/query.xq
#   echo 'count(//tei:body)' | ad-hoc-xquery.sh
# Env: EXISTDB_SERVER (default http://localhost:8080), EXISTDB_USER (admin), EXISTDB_PASS ("").
set -euo pipefail
SERVER="${EXISTDB_SERVER:-http://localhost:8080}"
USER="${EXISTDB_USER:-admin}"
PASS="${EXISTDB_PASS:-}"

if [ "${1:-}" ] && [ -f "${1}" ]; then QUERY="$(cat "${1}")"; else QUERY="$(cat -)"; fi

ENVELOPE=$(cat <<XML
<query xmlns="http://exist.sourceforge.net/NS/exist" wrap="no">
  <text><![CDATA[
${QUERY}
  ]]></text>
</query>
XML
)

curl -sS -u "${USER}:${PASS}" -H 'Content-Type: application/xml' \
  --data-binary "${ENVELOPE}" "${SERVER%/}/exist/rest/db"
echo
# A non-2xx with an <exception> body means the snippet didn't compile/run — read it carefully;
# eXist error messages point at the exact line/type mismatch.
