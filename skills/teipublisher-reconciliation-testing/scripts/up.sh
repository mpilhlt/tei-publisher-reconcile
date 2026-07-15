#!/usr/bin/env bash
# up.sh — start the TEI Publisher v10 container (podman) and wait until it's ready.
# Usage: up.sh [NAME] [HTTP_PORT] [IMAGE]
#   NAME      default teipub
#   HTTP_PORT default 8080 (maps host:container 8080:8080, the canonical v10 mapping)
#   IMAGE     default existdb/teipublisher:10.0.0   (pinned; use :latest to track)
# Omit the volume for an ephemeral DB (recreate = clean). This script uses a named volume.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

NAME="${1:-teipub}"
PORT="${2:-8080}"
IMAGE="${3:-docker.io/existdb/teipublisher:10.0.0}"
ENGINE="$(command -v podman || command -v docker)"

if "$ENGINE" container exists "$NAME" 2>/dev/null || "$ENGINE" ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "Container '$NAME' exists; starting it."
  "$ENGINE" start "$NAME" >/dev/null
else
  echo "Running $IMAGE as '$NAME' on host port $PORT…"
  "$ENGINE" run -d --name "$NAME" -p "${PORT}:8080" -v exist-data:/exist/data "$IMAGE" >/dev/null
fi

"$HERE/wait-ready.sh" "http://localhost:${PORT}"
echo "Jinks:  http://localhost:${PORT}/exist/apps/jinks"
echo "Apps:   http://localhost:${PORT}/exist/apps/<abbrev>"
