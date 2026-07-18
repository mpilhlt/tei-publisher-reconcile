#!/usr/bin/env bash
# ci-bootstrap-profile.sh — uploads the reconcile profile's source tree into a running
# Jinks server's own profile collection via the eXist REST API, so `jinks create`/
# `update` can then compose an app from it.
#
# Why this exists (not just `jinks watch`): a *stock* existdb/teipublisher image (what
# CI boots from scratch every run, no cached volume) has never heard of this repo's
# custom "reconcile" profile — its /db/apps/jinks/profiles/reconcile collection simply
# doesn't exist yet. Plain REST PUT does not auto-create missing parent collections
# (confirmed empirically), and jinks-cli's own upload endpoint has the same limitation
# for genuinely new nested paths - so the whole collection tree has to be pre-created,
# owned by the "tei" app user, before any file lands. This mirrors the exact recipe
# used throughout local development of this profile (see the "jinks-cli gotchas"
# project memory) - just scripted instead of done by hand once per session.
#
# Usage: ci-bootstrap-profile.sh [SERVER] [PROFILE_DIR]
#   SERVER      default http://localhost:8080
#   PROFILE_DIR default <repo-root>/reconcile
# Env: EXISTDB_USER (default admin), EXISTDB_PASS (default "").
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

SERVER="${1:-http://localhost:8080}"
PROFILE_DIR="${2:-$(cd "$HERE/../../.." && pwd)/reconcile}"
ADMIN_USER="${EXISTDB_USER:-admin}"
ADMIN_PASS="${EXISTDB_PASS:-}"
TARGET="/db/apps/jinks/profiles/reconcile"

echo "Bootstrapping reconcile profile from $PROFILE_DIR into $SERVER$TARGET"

# 1. Pre-create every directory in the tree (skipping doc/ - never part of the
#    generated-app payload, see reconcile/doc/README.md's own "What ships by default"
#    precedent for base10/registers). Passing every directory, not just leaves, is
#    harmless: local:mkcol is idempotent and recurses to parents on its own anyway.
DIR_LIST=$(find "$PROFILE_DIR" -type d ! -path '*/doc*' | sed "s#^$PROFILE_DIR#$TARGET#")

MKCOLS_XQ="$(mktemp)"
{
  echo 'declare function local:mkcol($path as xs:string) {'
  echo '    if (xmldb:collection-available($path)) then ()'
  echo '    else'
  echo '        let $parent := substring-before($path, "/" || tokenize($path, "/")[last()])'
  echo '        let $name := tokenize($path, "/")[last()]'
  echo '        return ('
  echo '            if ($parent = "" or xmldb:collection-available($parent)) then () else local:mkcol($parent),'
  echo '            xmldb:create-collection($parent, $name),'
  echo '            sm:chown(xs:anyURI($path), "tei"),'
  echo '            sm:chgrp(xs:anyURI($path), "tei"),'
  echo '            sm:chmod($path, "rwxrwxr-x")'
  echo '        )'
  echo '};'
  echo -n 'for $d in ('
  first=1
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    if [ "$first" -eq 1 ]; then first=0; else echo -n ', '; fi
    printf '"%s"' "$d"
  done <<< "$DIR_LIST"
  echo ') return local:mkcol($d)'
} > "$MKCOLS_XQ"

EXISTDB_USER="$ADMIN_USER" EXISTDB_PASS="$ADMIN_PASS" EXISTDB_SERVER="$SERVER" \
  "$HERE/ad-hoc-xquery.sh" "$MKCOLS_XQ"
rm -f "$MKCOLS_XQ"

# 2. Upload every file, skipping doc/, with a Content-Type matched to its extension -
#    critical: an omitted or wrong Content-Type has silently stored a zero-byte file
#    on this exact eXist version (application/xquery for .xql/.xqm executes-not-parses
#    on GET, so verify via util:binary-doc downstream, not a plain REST GET, if you
#    ever need to double check content here).
while IFS= read -r -d '' file; do
  rel="${file#"$PROFILE_DIR"/}"
  dest="$TARGET/$rel"
  case "$file" in
    *.json) ct="application/json" ;;
    *.xql|*.xqm) ct="application/xquery" ;;
    *.xml) ct="application/xml" ;;
    *.js) ct="application/javascript" ;;
    *) ct="text/plain" ;;
  esac
  status=$(curl -sS -u "$ADMIN_USER:$ADMIN_PASS" -X PUT -H "Content-Type: $ct" \
    --data-binary "@$file" -o /dev/null -w '%{http_code}' \
    "$SERVER/exist/rest$dest")
  if [ "$status" != "200" ] && [ "$status" != "201" ]; then
    echo "FAILED ($status): $rel" >&2
    exit 1
  fi
  echo "  uploaded: $rel ($ct)"
done < <(find "$PROFILE_DIR" -type f ! -path '*/doc/*' -print0)

echo "Profile source upload complete."
