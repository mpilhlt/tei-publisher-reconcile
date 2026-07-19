# Local test container — setup guide

This is the environment-setup companion to **[`README_MANUAL_TESTING.md`](README_MANUAL_TESTING.md)**,
which presupposes a running podman container with a generated `tp-reconc` app inside it. Read this
first if that container isn't up yet, if `jinks`/Node aren't working, or if you're setting this up
from scratch on a new machine. Once `curl http://localhost:8080/exist/apps/tp-reconc/api/reconcile`
returns a manifest JSON, go to `README_MANUAL_TESTING.md`.

---

## 0. What you need installed

- **podman** (this project targets podman specifically; docker is a drop-in fallback — the scripts
  below try `podman` first, then `docker`).
- **Node ≥22** — jinks-cli needs it (top-level await / modern ESM). The system default `node` here
  is often much older (nvm defaults can resolve to v15/v20). Check first:
  ```bash
  node --version
  ```
  If it's not ≥22:
  ```bash
  export NVM_DIR="$HOME/.nvm"; source "$NVM_DIR/nvm.sh"
  nvm install 22 && nvm use 22        # or: nvm use 22, if already installed
  node --version                       # should print v22.x
  ```
  **`nvm use` doesn't persist across separate shell invocations** — if you're scripting this (or an
  agent is), re-source + `nvm use 22` in every new shell/tool call rather than assuming it sticks.
- **jinks-cli** — this repo vendors it as a sibling checkout, `./tei-publisher-jinks-cli`. There's
  no global install needed; scripts below call it as `node tei-publisher-jinks-cli/index.js ...`. A
  convenience wrapper:
  ```bash
  jinks() {
    export NVM_DIR="$HOME/.nvm"; source "$NVM_DIR/nvm.sh"; nvm use 22 >/dev/null
    node "$(pwd)/tei-publisher-jinks-cli/index.js" "$@"
  }
  ```
  (or `npm install -g @teipublisher/jinks-cli` for a real global `jinks` on PATH, if you'd rather
  not vendor it — the scripts under `skills/.../scripts/` assume a `jinks` command exists on PATH
  either way).
- **curl**, **jq** (used throughout `README_MANUAL_TESTING.md`), **python3** (only for one
  batch-size-cap example that generates a large JSON payload).

---

## 1. Start the container

```bash
skills/teipublisher-reconciliation-testing/scripts/up.sh
```

What it does (`up.sh` → `wait-ready.sh`):
- If a container named `teipub` already exists (stopped or crashed), **starts it** (`podman start
  teipub`) — this is the common case, since the container is normally left around between sessions.
- Otherwise creates a fresh one: `podman run -d --name teipub -p 8080:8080 -v exist-data:/exist/data
  docker.io/existdb/teipublisher:10.0.0` — pinned to `10.0.0`, not `:latest`, for reproducibility.
  The named volume `exist-data` is what makes state (generated apps, uploaded profiles) durable
  across `up.sh` runs; omit `-v` yourself only if you deliberately want an ephemeral, always-clean DB.
- Polls `http://localhost:8080/exist/apps/jinks/` (following redirects) until it returns HTTP 200,
  up to a 180s timeout — eXist takes ~30–90s to fully boot, don't start testing before this returns.

Optional args: `up.sh [NAME] [HTTP_PORT] [IMAGE]` — e.g. `up.sh teipub 8080
docker.io/existdb/teipublisher:latest` to track the latest image instead of the pin.

**Rootless podman note:** this host has no `docker.io` short-name alias configured, so the image
must be the fully-qualified `docker.io/existdb/teipublisher:10.0.0` — `up.sh` already defaults to
that; if you invoke podman directly instead, use the fully-qualified name or it'll fail to resolve.

When it's done you should see:
```
Ready (HTTP 200).
Jinks:  http://localhost:8080/exist/apps/jinks
Apps:   http://localhost:8080/exist/apps/<abbrev>
```

Sanity check the container is actually healthy (not just "started"):
```bash
podman ps --format '{{.Names}} {{.Status}} {{.Ports}}'
curl -s http://localhost:8080/exist/apps/tp-reconc/api/reconcile | jq .   # if tp-reconc already exists
```

---

## 2. Create or update the `tp-reconc` demo app

**First time only** — create the app from the local profile source:
```bash
jinks create tp-reconc -c reconcile/config.json -s http://localhost:8080/exist/apps/jinks -u tei -p simple
```

**Every subsequent edit to the profile** — regenerate:
```bash
skills/teipublisher-reconciliation-testing/scripts/regenerate.sh tp-reconc          # incremental
skills/teipublisher-reconciliation-testing/scripts/regenerate.sh tp-reconc --all    # check every file
skills/teipublisher-reconciliation-testing/scripts/regenerate.sh tp-reconc -r       # full reinstall
```
This wraps `jinks update tp-reconc -s ... -u tei -p simple`. Credentials default to the app user
`tei`/`simple` (jinks-cli default); use `admin`/`` (empty password) only for DBA-level operations.

**Live-sync while iterating** (optional, keeps profile-source edits mirrored into eXist without a
manual re-push each time — still requires a `regenerate.sh` afterward to actually apply/expand
`.tpl.*` templates into the generated app):
```bash
skills/teipublisher-reconciliation-testing/scripts/watch-profile.sh ./reconcile   # leave running
```

**Important:** `.tpl.json`/`.tpl.xql` files only take effect after `jinks update` regenerates them
into their expanded form (`reconcile-api.json`/etc.) — editing the template alone and reloading the
browser will not show your change. If a change doesn't seem to take effect: confirm `jinks watch`
actually synced it, then confirm you re-ran `regenerate.sh`/`jinks update`.

Verify the app is live:
```bash
curl -s http://localhost:8080/exist/apps/tp-reconc/api/reconcile | jq .
```
That's the exact command `README_MANUAL_TESTING.md` section A starts from.

---

## 3. Everyday commands reference

| Task | Command |
|---|---|
| Start/resume container | `skills/teipublisher-reconciliation-testing/scripts/up.sh` |
| Regenerate app after profile edits | `skills/teipublisher-reconciliation-testing/scripts/regenerate.sh tp-reconc` |
| Live-sync profile source | `skills/teipublisher-reconciliation-testing/scripts/watch-profile.sh ./reconcile` |
| Run one XQuery snippet ad hoc | `skills/teipublisher-reconciliation-testing/scripts/ad-hoc-xquery.sh path/to/snippet.xq` |
| Check CORS on a route | `skills/teipublisher-reconciliation-testing/scripts/cors-check.sh http://localhost:8080/exist/apps/tp-reconc/api/reconcile` |
| Cypress API tests | `cd tp-reconc-checkout && npx cypress run` (Node ≥22 active) |
| XQSuite unit tests | see `skills/teipublisher-reconciliation-testing/scripts/ci-run-xqsuite.sh` (CI form) or run via eXide/`ad-hoc-xquery.sh` against `reconcile/test/xqsuite/*.xqm` |
| Stop container (keep data) | `podman stop teipub` |
| Full reset (fresh DB) | `podman rm -f teipub && podman volume rm exist-data`, then `up.sh` + step 2 again |

`ad-hoc-xquery.sh` and `cors-check.sh` both assume `EXISTDB_SERVER`/credentials default to
`http://localhost:8080` / `admin` / *(empty password)* — override via env vars, never hardcode
secrets into committed files. `JINKS_SERVER`/`JINKS_USER`/`JINKS_PASS` control the jinks-cli scripts
the same way (defaults: `http://localhost:8080/exist/apps/jinks` / `tei` / `simple`).

---

## 4. Troubleshooting

- **`up.sh` times out waiting for readiness** — check `podman logs teipub` for a crash/startup
  error. This host has hit two real causes before:
  - **Container exited/crashed** (`podman ps -a` shows `Exited (139)` or similar) — just `podman
    start teipub` again (or re-run `up.sh`, which does this automatically); the named volume means
    no data is lost. If it crashes repeatedly, check `podman logs teipub` for an OOM or native crash
    near the end of the log.
  - **Host disk full → eXist read-only mode** — if the container *is* running but every REST
    PUT/POST that writes fails with a bare `IOException: Database is read-only` (HTTP 500, empty
    body), the disk backing the container's data volume is likely full. eXist's `SyncTask` disk-space
    guard trips silently from the HTTP client's point of view — check the real cause:
    ```bash
    podman logs teipub 2>&1 | grep -i 'disk space\|read-only'
    df -h / /home     # this host's actual podman volume storage lives under /home
    podman system df  # see what's eating space — often old unrelated images
    ```
    Fix: free space (e.g. `podman image prune -a` — **ask before pruning if other projects might be
    using those images**, this is shared host state), then `podman restart teipub` to clear the
    read-only flag. No DB repair needed — it's purely a disk-space gate, not corruption.
- **`jinks create`/`jinks update` hangs or throws a cryptic ESM/syntax error** — almost always the
  active `node` is too old; re-check `node --version` is ≥22 (see §0). A subtler variant: some
  transitive deps (e.g. `cli-spinners`) need Node ≥20.10/21+ specifically for `import ... with
  {type:"json"}` syntax — Node 20.9 still fails even though it "looks" recent enough.
  Also see the project's `jinks-cli-gotchas` guidance (in this repo's Claude memory / prior session
  notes) if `watch`/`create` appear to silently corrupt state on a **brand-new** profile — regenerate
  from scratch with `-r` if something seems stuck rather than debugging incremental sync state.
- **Container image won't pull / "short-name resolution" error** — this host's rootless podman has
  no `docker.io` alias; always use the fully-qualified `docker.io/existdb/teipublisher:10.0.0` (which
  is what `up.sh` already defaults to — only relevant if you invoke `podman run`/`pull` yourself).
- **CORS failures from a browser client (testbench, OpenRefine, annotate editor)** — CORS is centralized,
  not per-route: the app echoes the request `Origin` only if it's in `config:origin-whitelist`
  (localhost/127.0.0.1 by default). Run `cors-check.sh` against the failing route/origin first — if
  it fails there too, it's a whitelist config issue, not a one-off route bug. Don't add per-route CORS
  code as a workaround.
- **SSH push hangs (unrelated to the container, but common right after a break)** — if `git push`
  over SSH hangs with no prompt, this shell has no `SSH_AUTH_SOCK`/running `ssh-agent`; unlock your
  key interactively (e.g. via the OS keyring prompt) and retry rather than waiting it out.

---

## 5. Full reset

To wipe all generated apps/uploaded profiles and start clean:
```bash
podman rm -f teipub
podman volume rm exist-data
skills/teipublisher-reconciliation-testing/scripts/up.sh
jinks create tp-reconc -c reconcile/config.json -s http://localhost:8080/exist/apps/jinks -u tei -p simple
```
Useful when you suspect leftover DB state is masking a bug — the project's own "definition of done"
requires re-running the full test suite once after exactly this kind of reset (or `jinks update
--all`) to prove nothing depends on stale state.

---

Once the app answers at `http://localhost:8080/exist/apps/tp-reconc/api/reconcile`, continue with
**[`README_MANUAL_TESTING.md`](README_MANUAL_TESTING.md)** for the actual exploration/testing walkthrough
(curl/Insomnia, browser, OpenRefine) and the presentation demo script.
