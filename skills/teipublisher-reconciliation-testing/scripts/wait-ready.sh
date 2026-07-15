#!/usr/bin/env bash
# wait-ready.sh — block until eXist answers, or time out.
# Usage: wait-ready.sh [BASE_URL] [TIMEOUT_SECONDS]
#   BASE_URL default http://localhost:8080
# eXist boots in ~30-90s; do NOT start testing before this returns 0.
set -euo pipefail
BASE="${1:-http://localhost:8080}"
TIMEOUT="${2:-180}"
# The Jinks app is always present in the v10 image and is a good readiness probe.
URL="${BASE%/}/exist/apps/jinks/"

echo "Waiting for ${URL} (timeout ${TIMEOUT}s)…"
deadline=$(( $(date +%s) + TIMEOUT ))
until code=$(curl -sL -o /dev/null -w '%{http_code}' "${URL}" || true); [ "${code}" = "200" ]; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "TIMED OUT after ${TIMEOUT}s (last HTTP ${code:-none}). Check: podman logs <name>" >&2
    exit 1
  fi
  printf '  …not ready (HTTP %s), retrying\n' "${code:-none}"
  sleep 3
done
echo "Ready (HTTP 200)."
