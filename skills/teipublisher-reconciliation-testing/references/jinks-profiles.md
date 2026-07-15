# Jinks profiles: building & deploying the reconciliation server, client in `annotate`

Authoritative sources (cite when relevant):
- Jinks repo (profiles, base10 controller/config, examples): https://github.com/eeditiones/jinks
- jinks-cli: https://www.npmjs.com/package/@teipublisher/jinks-cli
- roaster (Open API router): https://github.com/eeditiones/roaster
- TEI Publisher docker image & tldr: https://hub.docker.com/r/existdb/teipublisher
- xst (eXist CLI, for ad-hoc ops): https://github.com/eXist-db/xst

## Mental model

Jinks generates an eXist app by composing **profiles**. Three kinds: **blueprint** (a complete
app template), **feature** (adds one capability — our reconciliation server is a feature), and
**theme** (look & feel). Profiles `depends` on other profiles; configs are merged top-down, then
each profile's *write action* runs. Any file whose name contains `.tpl` is expanded as a Jinks
template during generation. Profiles live in the Jinks app's `profiles/` collection
(`/db/apps/jinks/profiles/<name>`); a custom profile is its own package that, once installed,
registers there.

## Anatomy of an API-serving feature profile (model: `dts`, `registers`)

```
profiles/reconcile/
├── config.json                       # profile manifest (see below)
├── modules/
│   ├── reconcile-api.tpl.json        # OpenAPI 3.0.3 spec (template → reconcile-api.json)
│   └── reconcile-api.xql             # roaster handler functions
├── doc/README.md
└── test/cypress/e2e/api/reconcile.cy.js   # API tests (see cypress-testing.md)
```

`config.json` (fields confirmed from `dts`/`registers`/`annotate`):

```jsonc
{
  "$schema": "../../schema/jinks.json",
  "type": "feature",
  "category": "development",
  "id": "https://e-editiones.org/app/tei-publisher/reconcile",  // unique URI = package id
  "version": "1.0.0",
  "label": "Reconciliation Service API",
  "description": "OpenRefine reconciliation endpoints (spec 0.2 and 1.0)",
  "order": 100,
  "depends": ["base10", "registers"],     // registers = the entity authorities you reconcile against
  "api": [
    {
      "prefix": "recon",                   // XQuery namespace prefix for handlers
      "id": "http://teipublisher.com/api/reconcile",
      "path": "reconcile-api.xql",         // handler module (under modules/)
      "spec": "reconcile-api.json"         // the GENERATED spec name (source: reconcile-api.tpl.json)
    }
  ]
}
```

The OpenAPI spec template uses Jinks placeholders, e.g. `"servers": [{ "url": "/exist/apps/[[$pkg?abbrev]]" }]`,
so the live routes sit at `/exist/apps/<app-abbrev>/api/reconcile`. Each route has
`operationId: "recon:<fn>"`, which roaster resolves to the function `recon:<fn>` in
`reconcile-api.xql`. Handlers take a single request map:

```xquery
xquery version "3.1";
module namespace recon="http://teipublisher.com/api/reconcile";
import module namespace router="http://e-editiones.org/roaster";

(: Manifest: GET /api/reconcile with no params :)
declare function recon:manifest($request as map(*)) { (: return a map -> JSON :) };

(: Reconcile: POST /api/reconcile :)
declare function recon:reconcile($request as map(*)) {
    let $batch := $request?body          (: parsed JSON body :)
    return (: ... return a result batch map ... :)
};
```

Read request params via `$request?parameters?<name>` and the body via `$request?body`. Use the
`dts` and `registers` handler modules as worked references for response shaping and content types.
**Roaster does not resolve `$ref`** in the OpenAPI document — keep the spec self-contained, or
bundle/dereference before it is used.

## Adding the client to the `annotate` profile (decoupled)

The `annotate` profile already contains the entity-authority UI
(`templates/pages/annotation/annotate-authorities.html`, the person/place/org/work editors) and
client web components under `resources/scripts/annotations/`. Put the reconciliation client there
as a JS resource wired into that UI. **Keep it decoupled**: the client takes a configurable
reconciliation-endpoint URL rather than hard-`depends`-ing on the server profile, so it can point
at any reconciliation service and the server profile stays independently testable. Add a `depends`
on the reconcile profile only if you want a single app that always bundles both.

## The dev loop with jinks-cli

Install once: `npm install -g @teipublisher/jinks-cli` (binary: `jinks`). Default server
`http://localhost:8080/exist/apps/jinks`; default app user `tei` / `simple` (use `-u admin -p ''`
for DBA-level operations).

1. **Scaffold** the profile: `jinks create-profile reconcile --out ./reconcile`. This creates the
   profile skeleton (config.json, expath-pkg.xml, repo.xml, build.xml). Build+install it once
   (`ant` → install the `.xar`) so Jinks registers it as a selectable profile.
2. **Live-sync edits**: `jinks watch ./reconcile` (wrapped by `scripts/watch-profile.sh`). It
   uploads changed files to the matching DB collection and removes deleted ones; the target
   collection and credentials come from the profile's `repo.xml` (`<target>` → `/db/apps/<target>`).
   Confirm `<target>` points into the Jinks `profiles/` collection. Leave it running.
3. **Create/Update the consuming app**:
   - First time: `jinks create <app-abbrev> -c <config.json>` (select your profile + base/theme).
   - Thereafter: `jinks update <app-abbrev>` (wrapped by `scripts/regenerate.sh`). Re-applies
     profiles to the existing app, **preserving unrelated local edits** and **reporting
     conflicts**. Use `--all` to check every file regardless of modified-date, `-r` to fully
     reinstall (overwrite), `--sync` to also pull changed files back to your local dir.
4. **Run actions** if needed: `jinks run <app> reindex` (or `-U` to update first).

For a one-off ad-hoc XQuery check that doesn't need the full app, `scripts/ad-hoc-xquery.sh` POSTs
a query envelope to eXist's REST endpoint. For pushing a single already-expanded `.xql` straight
into a generated app during fast debugging, `xst upload <file> /db/apps/<app>/modules/<file>` works
— but the canonical path for `.tpl.*` edits is watch + update, because templates must be expanded.

## CORS / origin-whitelist (central, not per-handler)

In `base10` the controller echoes the request `Origin` as `Access-Control-Allow-Origin` **iff** it
matches `config:origin-whitelist`, which defaults to localhost/127.0.0.1 only:

```
declare variable $config:origin-whitelist := (
    "(?:https?://localhost:.*|https?://127.0.0.1:.*)"
);
```

Allowed methods (`GET, POST, DELETE, PUT, PATCH, OPTIONS`) and headers (`Content-Type, api_key,
Authorization`) are already set centrally. So:

- **Local testbench + Cypress work unchanged** (localhost origins are whitelisted).
- To use the **hosted** testbench you would add `https?://reconciliation-api\.github\.io` to the
  generated app's `config:origin-whitelist` — a deliberate, security-relevant widening. The chosen
  default is local, so avoid this.
- Never add per-route CORS code in handlers; a CORS failure means the whitelist, not the handler.

## Container lifecycle (podman)

`podman` is drop-in for `docker`; if tooling insists on `docker`, install `podman-docker` or
`alias docker=podman`.

```bash
# Canonical v10 command (HTTP 8080; pin :10.0.0 for reproducibility instead of :latest)
podman run -d --name teipub -p 8080:8080 -v exist-data:/exist/data existdb/teipublisher:latest
scripts/wait-ready.sh http://localhost:8080      # eXist boots ~30-90s

podman logs -f teipub      # watch boot
podman rm -f teipub        # destroy container
podman volume rm exist-data  # wipe persisted DB for a clean run
```

Notes: this is the **dev** image (not safe on public servers). Default admin password is empty.
Rootless podman on Arch/Ubuntu publishes 8080 without extra privileges. SELinux `:z`/`:Z` volume
labels are only needed where SELinux is enforcing (check `getenforce`). On WSL2 run everything
inside the distro; `localhost:8080` is reachable there and from Windows via localhost forwarding.
For an **ephemeral** run, omit `-v` so recreating the container resets the DB; for a persistent dev
DB keep the named volume.
