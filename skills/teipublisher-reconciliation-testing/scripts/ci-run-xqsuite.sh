#!/usr/bin/env bash
# ci-run-xqsuite.sh — runs the reconcile profile's XQSuite unit test modules against a
# generated app and exits nonzero if anything failed, errored, or the suite itself
# couldn't even load (a compile error surfaces as an <exception> envelope, not a
# <testsuites> report - checked for explicitly, since a naive failures="0" grep would
# otherwise treat that as a false pass).
#
# Usage: ci-run-xqsuite.sh <abbrev> [server]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ABBREV="${1:?usage: ci-run-xqsuite.sh <abbrev> [server]}"
SERVER="${2:-http://localhost:8080}"

QUERY="$(mktemp)"
cat > "$QUERY" << XQEOF
import module namespace t1="http://teipublisher.com/api/reconcile/config/test" at "xmldb:exist:///db/apps/$ABBREV/test/xqsuite/reconcile-config.xqm";
import module namespace t2="http://teipublisher.com/api/reconcile/conditions/test" at "xmldb:exist:///db/apps/$ABBREV/test/xqsuite/reconcile-conditions.xqm";
import module namespace test="http://exist-db.org/xquery/xqsuite" at "resource:org/exist/xquery/lib/xqsuite/xqsuite.xql";
test:suite((util:list-functions("http://teipublisher.com/api/reconcile/config/test"), util:list-functions("http://teipublisher.com/api/reconcile/conditions/test")))
XQEOF

RESULT="$(EXISTDB_SERVER="$SERVER" "$HERE/ad-hoc-xquery.sh" "$QUERY")"
rm -f "$QUERY"

echo "$RESULT"

if echo "$RESULT" | grep -q "<exception>"; then
  echo "XQSuite run itself errored - see envelope above (likely a compile error in one of the test/source modules)." >&2
  exit 1
fi

total_failures=0
for n in $(echo "$RESULT" | grep -oE 'failures="[0-9]+"' | grep -oE '[0-9]+'); do
  total_failures=$((total_failures + n))
done
total_errors=0
for n in $(echo "$RESULT" | grep -oE 'errors="[0-9]+"' | grep -oE '[0-9]+'); do
  total_errors=$((total_errors + n))
done

if [ "$total_failures" != "0" ] || [ "$total_errors" != "0" ]; then
  echo "XQSuite: $total_failures failure(s), $total_errors error(s)." >&2
  exit 1
fi

echo "XQSuite: all tests passed."
