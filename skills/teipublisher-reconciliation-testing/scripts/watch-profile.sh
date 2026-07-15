#!/usr/bin/env bash
# watch-profile.sh — live-sync a local profile directory into its eXist collection via jinks-cli.
# Leave this running in the background while you edit; then run regenerate.sh to apply changes.
# Usage: watch-profile.sh [PROFILE_DIR]
#   PROFILE_DIR default ./reconcile
# Env: JINKS_SERVER (default http://localhost:8080/exist/apps/jinks)
#      JINKS_USER / JINKS_PASS  (override repo.xml credentials if needed)
# jinks watch reads the target collection and credentials from repo.xml in PROFILE_DIR;
# confirm its <target> points into the Jinks profiles collection.
set -euo pipefail
DIR="${1:-./reconcile}"
SERVER="${JINKS_SERVER:-http://localhost:8080/exist/apps/jinks}"

if ! command -v jinks >/dev/null 2>&1; then
  echo "jinks-cli not found. Install it: npm install -g @teipublisher/jinks-cli" >&2
  exit 127
fi

args=(watch "$DIR" -s "$SERVER")
[ "${JINKS_USER:-}" ] && args+=(-u "$JINKS_USER")
[ "${JINKS_PASS:-}" ] && args+=(-p "$JINKS_PASS")

echo "jinks ${args[*]}"
exec jinks "${args[@]}"
