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

**First time only** (or after a fresh/reset volume — see the troubleshooting note on data loss
after a container crash, below) — this is a **two-step** process, not one command:

**2a. Register the `reconcile` profile with the Jinks server.** A stock/reset container has never
heard of a custom profile living only in this checkout — its `/db/apps/jinks/profiles/reconcile`
collection simply doesn't exist yet, so nothing can `extends` it. The CI-proven, no-interaction way
to upload it (pre-creates the collection tree with correct ownership, then PUTs every file with the
right `Content-Type`):
```bash
skills/teipublisher-reconciliation-testing/scripts/ci-bootstrap-profile.sh http://localhost:8080 ./reconcile
```
(Equivalently, `jinks create-profile`/`jinks watch ./reconcile` can register+sync it interactively —
see `skills/teipublisher-reconciliation-testing/references/jinks-profiles.md` — but the bootstrap
script is faster and scriptable.)

**2b. Create the app.** `jinks create -c <file>` expects an **app-level** configuration — `pkg.abbrev`
plus an `extends` array naming which profiles to compose — **not** `reconcile/config.json` itself
(that file is the *profile's own manifest*: `depends`/`api`/etc., with no `pkg` field at all). Passing
the profile manifest directly to `-c` crashes jinks-cli with `TypeError: Cannot read properties of
undefined (reading 'abbrev')` (it tries to read `config.pkg.abbrev` and `pkg` is missing) — this is a
real, reproducible jinks-cli 2.4.0 bug in `editOrCreateConfiguration`/`config.js`, not a typo to just
retry. Write an app-level config first:
```bash
cat > /tmp/tp-reconc-app-config.json <<'EOF'
{
    "overwrite": "default",
    "label": "TEI Publisher Reconciliation Demo",
    "id": "https://e-editiones.org/apps/tp-reconc",
    "extends": ["base10", "demo-data", "registers", "reconcile"],
    "pkg": { "abbrev": "tp-reconc" },
    "description": "Demo app for the OpenRefine Reconciliation Service profile"
}
EOF
jinks create tp-reconc -c /tmp/tp-reconc-app-config.json -s http://localhost:8080/exist/apps/jinks -u tei -p simple
```
(This mirrors `.github/workflows/ci.yml`'s "Create the test app" step exactly — that's the
authoritative reference if this drifts again.)

**2c. Optional — testing the annotation editor UI in a browser.** The config above is enough for
curl/Cypress/the testbench/OpenRefine (everything in section 3 below and `README_MANUAL_TESTING.md`
sections A/C). If you also want to click through the **annotation editor** (see
`README_MANUAL_TESTING.md` §B3 for the full click path and known open issues), use this extended
config instead — it adds `upload`, `jinntap`, `annotate`, `theme-base10`, and switches the theme
palette to `neutral` (the default theme renders the annotate UI unusably):
```json
{
    "theme": { "colors": { "palette": "neutral" } },
    "overwrite": "default",
    "label": "TEI Publisher Reconciliation Demo",
    "id": "https://e-editiones.org/apps/tp-reconc",
    "extends": ["base10", "demo-data", "theme-base10", "registers", "reconcile", "upload", "jinntap", "annotate"],
    "pkg": { "abbrev": "tp-reconc" },
    "description": "Demo app for the OpenRefine Reconciliation Service profile"
}
```
This path needs two things fixed before the annotate view actually works — both fixed 2026-07-24 and
covered in Troubleshooting (§4) below: a `tei-publisher-lib` package upgrade (the `XQDY0025` entry),
and copying a complete `annotation-config.xqm` over from `tp-workbench` (the entry right after it).

**Use `-c` on the `jinks update`, not a bare `jinks update tp-reconc`.** There is no separate
"apply the theme" build step distinct from the normal generate/update pipeline — clicking **Apply**
in the Jinks web UI just POSTs whatever config is in the browser's JSON editor to the same
`api/generator` endpoint that `jinks create`/`jinks update` already use (confirmed by reading
`tei-publisher-jinks/resources/scripts/editor.js`). The reason a bare `jinks update tp-reconc` looks
like it "doesn't apply the theme" is that **`update` without `-c` re-fetches and re-POSTs the
*currently-installed* config** (`loadConfigFromApplication` in jinks-cli), which doesn't know about
the theme/extra profiles until you've explicitly pushed a config that includes them:
```bash
jinks update tp-reconc -c /tmp/tp-reconc-app-config.json -s http://localhost:8080/exist/apps/jinks -u tei -p simple
```
Do this once with the extended config above; after that, the *installed* config includes the theme,
so plain `jinks update tp-reconc` (or `regenerate.sh tp-reconc`) keeps it applied on later edits —
exactly like the existing `-c`-vs-bare-`update` distinction already documented for `jinks create`.

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

**Recreating just `tp-reconc` cleanly, without a full container/volume reset.** Useful for checking
whether a problem is real or session-specific stale state (this exact recipe caught a false alarm on
2026-07-24 — see `README_MANUAL_TESTING.md` §B3). A plain `podman`/collection delete is **not**
enough — the Jinks server also tracks apps as installed EXPath packages, and `jinks create` will
fail with `Collection /db/apps/tp-reconc not found` if you only delete the collection while the
package registration still exists. Properly unregister first:
```bash
cat > /tmp/undeploy-tp-reconc.xq <<'EOF'
import module namespace repo="http://exist-db.org/xquery/repo";
(repo:undeploy("https://e-editiones.org/apps/tp-reconc"), repo:remove("https://e-editiones.org/apps/tp-reconc"))
EOF
EXISTDB_USER=admin skills/teipublisher-reconciliation-testing/scripts/ad-hoc-xquery.sh /tmp/undeploy-tp-reconc.xq
curl -sS -u admin: -X DELETE "http://localhost:8080/exist/rest/db/apps/tp-reconc"   # belt-and-braces
jinks create tp-reconc -c /tmp/tp-reconc-app-config.json -s http://localhost:8080/exist/apps/jinks -u tei -p simple
```
(the app's own package id, `https://e-editiones.org/apps/tp-reconc`, comes from the `"id"` field in
your app-level config — swap it if you used a different one). The `reconcile` profile registration
itself (§2a) is untouched by this and doesn't need redoing.

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
  - **Container exited/crashed** (`podman ps -a` shows `Exited (139)` or similar — `139` is a
    SIGSEGV) — `podman start teipub` again (or re-run `up.sh`, which does this automatically). The
    named volume usually preserves data across this, **but not always**: a JVM segfault can lose
    anything eXist hadn't checkpointed to disk yet, even though the volume itself survives. Confirmed
    once on this host — a generated `tp-reconc` app and its `reconcile` profile registration that
    worked fine in one session were both **silently gone** (404 / `xmldb:collection-available()`
    false) after the container crashed and was restarted, with no error at restart time. **Don't
    assume "the container is up" means "my app is still there"** — re-verify with a real request
    (`curl .../api/reconcile`) before debugging application logic, and if it's gone, just redo step 2
    (bootstrap the profile + `jinks create` again — cheap, a few seconds). If it happens often, check
    `podman logs teipub` for what's actually segfaulting.
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
- **`jinks create ... -c ... ` throws `TypeError: Cannot read properties of undefined (reading
  'abbrev')`** — you passed `reconcile/config.json` (the profile's own manifest) as the `-c` file.
  `-c` wants an app-level config (`pkg.abbrev` + `extends: [...]`); the profile manifest has no
  `pkg` at all, so jinks-cli's `config.pkg.abbrev` lookup throws. See §2 above for the correct
  two-step sequence (bootstrap the profile, then `jinks create` with a real app config).
- **`err:XQDY0025: element has more than one attribute 'data-tei'` in the annotate view — fixed
  2026-07-24, upstream, in `tei-publisher-lib`, not by patching the generated app.**
  `transform/teipublisher-web.xql` is *compiled output* of TEI Publisher's ODD→XQuery compiler;
  the real bug was in `model:map()`, `tei-publisher-lib/content/model.xql` (~line 303-314), which
  unconditionally wrote `attribute data-tei { util:node-id($context) }` onto every tracked element
  without checking whether one already existed. Fixed by guarding it
  (`if ($node/@data-tei) then () else attribute data-tei {...}`), bumping the package to `6.1.1`,
  building a new `.xar` (`cd tei-publisher-lib && ant`), and installing it into the running
  container in place of the stock package:
  ```bash
  curl -sS -u admin: -X PUT -H "Content-Type: application/octet-stream" \
    --data-binary @tei-publisher-lib/build/tei-publisher-lib.xar \
    "http://localhost:8080/exist/rest/db/tei-publisher-lib-6.1.1.xar"
  echo 'import module namespace repo="http://exist-db.org/xquery/repo";
        repo:install-and-deploy-from-db("/db/tei-publisher-lib-6.1.1.xar")' \
    | EXISTDB_USER=admin skills/teipublisher-reconciliation-testing/scripts/ad-hoc-xquery.sh
  ```
  Then **recompile every app's ODDs** — a package upgrade does not retroactively fix already-compiled
  `transform/*.xql` files sitting in an app's collection; the package's own changelog note says
  exactly this ("Generated apps may fail after updating. Make sure to recompile your ODDs."):
  ```bash
  curl -sS -u tei:simple -X POST "http://localhost:8080/exist/apps/tp-reconc/api/odd"
  ```
  Verified: after this, every ODD (including `annotations`) recompiles with no errors, and the
  installed `content/model.xql` contains the guard (checked via `repo:get-resource(...,
  "content/model.xql")`). Confirmed at the code level too, not just "no compile error": invoking the
  compiled transform directly with `map { "track-ids": true() }` (the exact parameter that turns on
  the vulnerable `model:map` path) against a real annotated document produced correct output with no
  duplicate `@data-tei` — see the `tei_publisher_lib_data_tei_fix` project memory for the exact query.

  **A second, separate issue you may hit adding `annotate`/`upload`/`jinntap`, seen once (2026-07-23)
  but NOT reproducible from a fresh app (confirmed 2026-07-24 — see below):** an app's
  `modules/annotations/annotation-config.xqm` missing three functions (`anno:annotations`,
  `anno:occurrences`, `anno:fix-namespaces`) that `annotate`'s own `annotations.xql` imports — and
  because XQuery module imports are resolved eagerly, that breaks roaster's *entire* composed router,
  not just annotate routes (`/api/reconcile` included). **This turned out to be session-specific
  stale state, not a real bug** — deleting `tp-reconc` completely and recreating it from scratch
  produced a byte-identical, working `annotation-config.xqm` with no manual intervention (see
  "Full reset" §5 for the proper deletion sequence — a plain collection delete is not enough, the
  Jinks server also tracks apps as installed EXPath packages via `repo:list()`). If you ever see this
  error again despite a genuinely fresh app, the workaround is to copy the working file from the
  `tp-workbench` demo app (fetched as binary/base64 to avoid both the "plain GET executes .xqm as a
  module" gotcha and eXist's XML-entity-escaping of a plain string query result, which would corrupt
  the `<persName>`-style element constructors in the source):
  ```bash
  echo 'util:binary-doc("/db/apps/tp-workbench/modules/annotations/annotation-config.xqm")' \
    | EXISTDB_USER=admin skills/teipublisher-reconciliation-testing/scripts/ad-hoc-xquery.sh | base64 -d \
    | curl -sS -u tei:simple -X PUT -H "Content-Type: application/xquery" --data-binary @- \
        "http://localhost:8080/exist/rest/db/apps/tp-reconc/modules/annotations/annotation-config.xqm"
  ```
  then recompile ODDs again (`POST /api/odd` as above). See `README_MANUAL_TESTING.md` §B3 and the
  `annotate_reconciliation_client`/`tei_publisher_lib_data_tei_fix` project memories for the full
  investigation, including why this isn't a `tei-publisher-jinks` "delegation mechanism" bug (it
  isn't — the Jinks server's own bundled `annotate` profile is a plain, non-templated, already-working
  copy; the templated `features.annotate.configs` design only exists in this project's unrelated,
  never-deployed local `./tei-publisher-jinks` git checkout).
- **The annotation editor's Reconciliation connector queries `https://api.metagrid.ch/...` instead of
  the local endpoint** — this is not a bug in this profile's server code; it's `annotate.html`'s
  default `person` authority wiring (`connector="Custom"` → `GND`), plus a silent footgun in
  `tei-publisher-components`'s `createConnectors()`: **any** unrecognized `connector` attribute value
  (e.g. the natural-seeming typo `connector="Reconciliation"`) falls back to the unrelated `Metagrid`
  connector with no error at all. Fix — wire `person` (or whichever type you're demoing) to the exact,
  case-sensitive connector name, directly in the generated app's `templates/pages/annotate.html`:
  ```bash
  cat > /tmp/fix-person-authority.xq <<'EOF'
  declare namespace html="http://www.w3.org/1999/xhtml";
  let $doc := doc("/db/apps/tp-reconc/templates/pages/annotate.html")
  let $person := $doc//*[local-name() = 'pb-authority'][@name = 'person']
  return update replace $person with
      <pb-authority connector="ReconciliationService" name="person"
          endpoint="/exist/apps/tp-reconc/api/reconcile" type="person" edit=""/>
  EOF
  EXISTDB_USER=tei EXISTDB_PASS=simple skills/teipublisher-reconciliation-testing/scripts/ad-hoc-xquery.sh /tmp/fix-person-authority.xq
  ```
  Covered by an automated regression test now, so it won't silently regress unnoticed again:
  `reconcile/test/cypress/e2e/gui/annotate-reconciliation.cy.js` (its own `before()` hook applies this
  same fix idempotently, so the test doesn't depend on this manual step having been run first — but a
  human clicking through the editor still needs it applied, since only the test runs the hook).
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
skills/teipublisher-reconciliation-testing/scripts/ci-bootstrap-profile.sh http://localhost:8080 ./reconcile
jinks create tp-reconc -c /tmp/tp-reconc-app-config.json -s http://localhost:8080/exist/apps/jinks -u tei -p simple  # see §2b for the file's contents
```
Useful when you suspect leftover DB state is masking a bug — the project's own "definition of done"
requires re-running the full test suite once after exactly this kind of reset (or `jinks update
--all`) to prove nothing depends on stale state.

---

Once the app answers at `http://localhost:8080/exist/apps/tp-reconc/api/reconcile`, continue with
**[`README_MANUAL_TESTING.md`](README_MANUAL_TESTING.md)** for the actual exploration/testing walkthrough
(curl/Insomnia, browser, OpenRefine) and the presentation demo script.
