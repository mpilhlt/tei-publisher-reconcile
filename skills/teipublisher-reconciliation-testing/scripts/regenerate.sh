#!/usr/bin/env bash
# regenerate.sh — re-apply profiles to a generated app (the deploy step) via jinks-cli.
# Usage: regenerate.sh APP_ABBREV [extra jinks update flags…]
#   e.g. regenerate.sh tp-myapp            (incremental, by modified-date)
#        regenerate.sh tp-myapp --all      (check every file)
#        regenerate.sh tp-myapp -r         (full reinstall / overwrite)
# Env: JINKS_SERVER (default http://localhost:8080/exist/apps/jinks)
#      JINKS_USER (default tei), JINKS_PASS (default simple)  — use admin/'' for DBA ops.
# First-time app creation instead uses:  jinks create <abbrev> -c <config.json>
set -euo pipefail
APP="${1:?usage: regenerate.sh APP_ABBREV [flags]}"; shift || true
SERVER="${JINKS_SERVER:-http://localhost:8080/exist/apps/jinks}"
USER="${JINKS_USER:-tei}"
PASS="${JINKS_PASS:-simple}"

if ! command -v jinks >/dev/null 2>&1; then
  echo "jinks-cli not found. Install it: npm install -g @teipublisher/jinks-cli" >&2
  exit 127
fi

echo "jinks update $APP -s $SERVER -u $USER $*"
jinks update "$APP" -s "$SERVER" -u "$USER" -p "$PASS" "$@"
echo "Done. Remember: .tpl.* files only take effect after this regeneration step."
