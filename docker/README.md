# Reconciliation demo image

A self-contained image with the `reconcile` profile, the patched `annotate` profile (dispatcher
+ field-mapping fixes — see the `annotation_config_dispatcher_dormant` project memory), and a
self-hostable `tei-publisher-components` build all baked in. `docker run` and it's up — no manual
`jinks create`/profile upload steps.

## Build

From the repo root (needs `reconcile/`, `tei-publisher-jinks/`, and `tei-publisher-components/`
checked out as siblings, same as the rest of this project):

```bash
podman build -f docker/Dockerfile -t tp-reconc-demo .
# or: docker build -f docker/Dockerfile -t tp-reconc-demo .
```

Two Node-based builder stages need network access (npm installs) and take a few minutes the
first time; the final stage itself is just file copies, so rebuilds after a small source change
are fast.

## Run

```bash
podman run -d --name tp-reconc-demo -p 8080:8080 tp-reconc-demo
```

First boot takes ~30–90s longer than a normal restart — that's when the container deploys the
`reconcile`/`annotate` profiles to the Jinks server and runs `jinks create` for you. Watch
`podman logs -f tp-reconc-demo`; it prints "Ready:" with the app URLs once done.

```
http://localhost:8080/exist/apps/tp-reconc/api/reconcile
http://localhost:8080/exist/apps/tp-reconc
```

## The self-hosted vs. CDN switch

By default (`PB_COMPONENTS_SOURCE=self-hosted`) the app loads `pb-*` web components from the
build baked into this image, served from the app's own `resources/lib/` — same origin, no CORS,
no separate port — via base10's `script.webcomponents: "local"` mode. To use the standard,
publicly-released `@teipublisher/pb-components` from jsDelivr instead (e.g. once your own fixes
have been merged upstream and released, and you no longer need the self-hosted build):

```bash
podman run -d --name tp-reconc-demo -p 8080:8080 \
  -e PB_COMPONENTS_SOURCE=cdn \
  tp-reconc-demo
```

This is a pure runtime switch — the *same image*, no rebuild — because `entrypoint.js` re-applies
the app's `config.json` `script` block on every container start, not just the first one. Flip it
back and forth across restarts freely.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `PB_COMPONENTS_SOURCE` | `self-hosted` | `self-hosted` or `cdn` — see above. |
| `HTTP_PORT` | `8080` | eXist's port *inside* the container — change your `-p` mapping, not this, for a different host port. |
| `APP_ABBREV` | `tp-reconc` | Generated app name. |
| `ADMIN_USER` / `ADMIN_PASS` | `admin` / *(empty)* | eXist DBA credentials, used only for the first-boot setup. |
| `APP_USER` / `APP_PASS` | `tei` / `simple` | jinks-cli app-level credentials. |

## Data persistence

No volume is declared by default — a removed container loses all state, and a fresh container
always starts from the same pristine demo data. This is deliberate for a *public demo* (state
drift/vandalism resets on restart, which is usually what you want). If you need persistence
across restarts, mount your own volume at `/exist/data` — the first boot on an empty volume runs
the same setup as an ephemeral run; a volume that already has a previously-initialized app in it
skips setup and starts directly (the `resources/lib/` components upload and the `script`
config, though, are re-applied on *every* boot regardless, so a rebuilt image's newer components
still reach an app on a persisted volume without a full re-init).

## Why a custom entrypoint at all

The base image (`existdb/teipublisher:10.0.0`) has no shell and no coreutils — confirmed by
`podman exec teipub /bin/sh`, which fails with "executable file not found". Everything here
(`entrypoint.js`, jinks-cli) runs as plain Node scripts invoked directly (`node /path/to/script.js`),
never relying on a shebang or shell resolution — Node itself was copied in from a normal
`node:20-slim` image (confirmed to run correctly against this base image's glibc). See
`entrypoint.js`'s own header comment for the full first-boot sequence.

## Verified end to end

Built and run locally with podman, from a completely clean first boot with no manual steps:
`reconcile` (36 files) and the patched `annotate` profile (34 files) deployed, app created,
components deployed, `/api/reconcile` answered a real manifest, the annotate editor route
returned 200, and `/api/annotations/occurrences` correctly returned a nonzero count for a
field-mapped entity (confirming the `annotation_config_dispatcher_dormant` fix is live in the
image, not just in source). Also confirmed: a served page's `<script src=...>` tag points at
`resources/lib/` (not jsDelivr) with `PB_COMPONENTS_SOURCE=self-hosted`, and switches to jsDelivr
with `=cdn` on a restart against the *same* persisted `/exist/data` volume — no rebuild, both
directions.

Two real bugs surfaced and were fixed during this verification, not just the happy path:
- `dist/api.html` (a docs page bundled by `tei-publisher-components`'s own build, not something
  this project wrote) has a plain, valid-HTML-but-not-valid-XML `&` in an inline CSS
  `@import url(...)` — eXist's REST PUT parses `text/html` bodies as XML before storing them, so
  uploading it with that Content-Type failed with a bare 400. Fixed by storing `.html` under
  `resources/lib/` as `application/octet-stream` instead (fine there — nothing serves those pages,
  only the `.js` files, which keep their real MIME type, actually matter for component loading).
- Setting `config.json`'s `script` block alone had no visible effect at first: `base.html`'s
  `script.webcomponents` check reads from `modules/generated-config.xql`, which is generated
  *once*, at app creation/update time, from `base10/modules/generated-config.tpl.xqm` — not
  re-read live from `config.json` per request. `entrypoint.js` now runs `jinks update` right
  after the `config.json` PUT specifically to regenerate that module; skipping it left the raw
  config file changed but every already-compiled page still serving the old value.

A second round of testing — this time rebuilding from a completely clean podman cache (only the
base `existdb/teipublisher` image kept) — surfaced four more real bugs, all now fixed:

- **Missing UI translations** (`facets.genre`, `search.placeholder`, `browse.items`, `login.user`,
  `login.password`, ... rendered as raw i18next keys). Root cause: `pb-page.js`'s i18next backend
  loads translations from `resources/i18n/{{ns}}/{{lng}}.json`, sourced from a top-level `i18n/`
  folder in `tei-publisher-components` — a sibling of `dist/`, never bundled inside it and never
  previously deployed by this image. Fixed by adding a second `deployTree()` call in
  `deployComponents()` that uploads `tei-publisher-components/i18n` to `resources/i18n`.
- **"template annotate-.html not found"** when switching from the normal document view to the
  annotation editor. Root cause: the `toggle` template in `annotate`'s
  `templates/annotation-blocks.html` built its link from `$context?doc?type`, which — in this
  app's actually-deployed `base10` (confirmed to differ from the `tei-publisher-jinks` git
  history, same class of drift as the `annotation_config_dispatcher_dormant` finding) — reaches
  the template empty instead of populated. Fixed pragmatically by computing the doctype directly
  from the reliably-present `$context?doc?content` node instead:
  `config:document-type($context?doc?content/*)`.
- **`err:XQDY0025: element has more than one attribute 'data-tei'`** crashing the annotate view.
  This project's `tei-publisher-lib` checkout already carries the fix (bumped to `6.1.1`, see the
  `tei_publisher_lib_data_tei_fix` project memory) but the image never baked it in — only the dev
  container had it manually installed, which a full cache wipe erases. Fixed by adding a
  `lib-builder` Dockerfile stage that runs `ant xar` against the patched checkout and drops the
  result into `/exist/autodeploy/`, eXist's own "install this at startup" convention. The
  first-boot ODD recompile now also retries a few times: `/api/odd` is gated by `x-constraints`
  (a group-membership check, not a bad-password check — roaster's `auth.xql` returns the same
  bare "Access denied" 401 either way), and that membership doesn't always propagate before
  `jinks create` returns; the identical request retried a few seconds later succeeds.
- **Raw Fore markup visibly leaking in the annotation editor's side panel** (JS function bodies,
  `falsefalsefalsetrue`-style instance data, a permanently-visible "Cannot save to local register.
  Please log in!" message even while logged in). Root cause, found via a Playwright check
  (`customElements.get('fx-fore')` returned `undefined`): the `forms` profile's own
  `templates/forms-blocks.html` gates its `fore.js`/`fore.css` `<script>`/`<link>` tags on
  `$features?forms?enabled`, a flag its own `config.json` never sets — so those tags never render
  and the `<fx-fore>` custom element never upgrades, leaving its raw markup visible as plain text.
  Worse, `forms` is only reachable *transitively* (`annotate` depends on it) — Jinks only merges a
  profile's `config.json` `features` block for profiles the **app** directly extends, not
  transitive dependencies, so fixing the flag alone wasn't enough. Fixed both parts: this
  project's own patched `tei-publisher-jinks/profiles/forms/config.json` sets
  `features.forms.enabled: true` and is now deployed by `entrypoint.js` (same pattern as
  `annotate`/`reconcile`), *and* `docker/app-config.json`'s `extends` list now lists `forms`
  directly, not just via `annotate`.

All four were re-verified together against a fully fresh `podman build` + `podman run` (no reused
layers beyond the base image, no persisted volume): i18n resources serve real translations, the
annotate view has no `XQDY0025`, the ODD recompile succeeds, and a Playwright check confirms
`fx-fore` upgrades correctly with none of the raw-markup strings visible in the rendered page.

## Known limitations / next steps

- Setup happens at container *first boot*, not baked into the image layers — simpler and more
  robust given the base image has no shell to run setup *during* `docker build`, at the cost of
  a slower first start. True build-time baking is possible (e.g. via a `docker commit`-based
  build step outside plain Dockerfile `RUN` semantics) but wasn't attempted here; flag if you
  want it.
- `tei-publisher-components`'s committed `package-lock.json` has drifted from `package.json` in
  this checkout — the Dockerfile uses `npm install`, not `npm ci`, to tolerate that. Regenerating
  a clean lockfile (and switching to `ci`) would make builds more reproducible.
