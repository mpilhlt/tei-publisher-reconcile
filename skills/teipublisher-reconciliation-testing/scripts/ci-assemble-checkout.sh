#!/usr/bin/env bash
# ci-assemble-checkout.sh — assembles a runnable Cypress project directory for a
# generated app, without relying on `jinks update --sync` (which only ever downloads
# files that changed as part of *that specific* generator run, not a full checkout -
# useless for a CI run that never had a prior local copy to diff against).
#
# Instead: the handful of generic scaffold files a Cypress run needs (package.json,
# cypress.config.cjs, test/cypress/support/{e2e,commands}.js - all base10-provided,
# not reconcile-specific) are fetched directly from the app's own deployed collection
# via the eXist REST API (NOT a plain app-route GET, which 404s to an HTML "Ooops"
# page with HTTP 200 - confirmed empirically), and the reconcile-specific spec +
# fixtures are simply copied from this repo's own checkout (already on disk from
# actions/checkout - no need to fetch back what was just uploaded).
#
# Usage: ci-assemble-checkout.sh <abbrev> <dest-dir> [server]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

ABBREV="${1:?usage: ci-assemble-checkout.sh <abbrev> <dest-dir> [server]}"
DEST="${2:?usage: ci-assemble-checkout.sh <abbrev> <dest-dir> [server]}"
SERVER="${3:-http://localhost:8080}"
ADMIN_USER="${EXISTDB_USER:-admin}"
ADMIN_PASS="${EXISTDB_PASS:-}"

mkdir -p "$DEST"

fetch() {
  local rel="$1"
  local out="$DEST/$rel"
  mkdir -p "$(dirname "$out")"
  local status
  status=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASS" -o "$out" -w '%{http_code}' \
    "$SERVER/exist/rest/db/apps/$ABBREV/$rel")
  if [ "$status" != "200" ]; then
    echo "FAILED to fetch $rel (HTTP $status)" >&2
    exit 1
  fi
  echo "  fetched: $rel"
}

for f in package.json cypress.config.cjs test/cypress/support/e2e.js test/cypress/support/commands.js; do
  fetch "$f"
done

mkdir -p "$DEST/test/cypress/e2e/api" "$DEST/test/cypress/fixtures"
cp "$REPO_ROOT/reconcile/test/cypress/e2e/api/reconcile.cy.js" "$DEST/test/cypress/e2e/api/"
cp -r "$REPO_ROOT/reconcile/test/cypress/fixtures/schemas" "$DEST/test/cypress/fixtures/"

echo "Checkout assembled at $DEST"
