# Reconciliation demo image

A self-contained image with the `reconcile` profile, the patched `annotate` profile[^1], a
self-hostable `tei-publisher-components` build, and patched `tei-publisher-lib` (`6.1.1`) and
`roaster` (`1.13.0`) packages all baked in. `docker run` (or `podman run`) and it's up — no manual
profile upload or `jinks create` steps. Currently published as
`ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:0.1.2` (and `:latest`).

[^1]: In the context of the reconciliation project, the `annotate` profile included with
`tei-publisher-jinks` was updated to integrate mapping of multiple authority db fields to
different XML constructs — see the `annotation_config_dispatcher_dormant` project memory.

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

If `podman build` fails with `short-name "..." did not resolve to an alias and no
containers-registries.conf(5) was found`: your podman has no `docker.io` entry in its
unqualified-search-registries, and this Dockerfile already uses fully-qualified image names
(`docker.io/library/node:20-slim`, `docker.io/existdb/teipublisher:10.0.0`, ...) specifically to
avoid depending on that config — if you still hit this on an older checkout, `git pull` to pick up
that fix, or add `unqualified-search-registries = ["docker.io"]` to
`/etc/containers/registries.conf` / `~/.config/containers/registries.conf` yourself.

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

The base image (`existdb/teipublisher:10.0.0`) has no shell and no coreutils. Likewise, everything
here (`entrypoint.js`, jinks-cli) runs as plain Node scripts invoked directly
(`node /path/to/script.js`), never relying on a shebang or shell resolution — Node itself was
copied in from a normal `node:20-slim` image. See `entrypoint.js`'s own header comment for the
full first-boot sequence.

## Testing

For some standard ways to test and verify the functionality of the running container, see the
comments in [../README_MANUAL_TESTING.md](../README_MANUAL_TESTING.md).

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
  Concretely, any request that loads a document through `annotate`'s track-ids mode — e.g.
  `GET /api/document/{id}?user.track-ids=yes`, which `annotate-tei.html`'s
  `<pb-param name="track-ids" value="yes">` triggers on every page load, so any `cy.visit()` of an
  annotate URL in `reconcile/test/cypress/e2e/gui/annotate-reconciliation.cy.js` (e.g.
  `/sermons/27004.xml?template=annotate-tei.html&odd=annotations&view=single`) reproduces it —
  500s on an unpatched `tei-publisher-lib`, because `model:map()` unconditionally re-added a
  `data-tei` tracking attribute even onto nodes that already carried one. This project's
  `tei-publisher-lib` checkout already carries the fix (bumped to `6.1.1`, see the
  `tei_publisher_lib_data_tei_fix` project memory) but the image never baked it in — only the dev
  container had it manually installed, which a full cache wipe erases. First attempt: a
  `lib-builder` Dockerfile stage building the `.xar` and dropping it into `/exist/autodeploy/`,
  eXist's own "install this at startup" convention — **this alone turned out not to be enough**:
  the base image already ships `tei-publisher-lib-6.0.2` as an installed package, and
  `/exist/autodeploy/`'s startup scan dedupes purely by package ID ("Application package ...
  already installed. Skipping.") with no version comparison, so the 6.1.1 xar silently lost to
  the stock 6.0.2 every time and the bug stayed live even with the xar correctly baked into the
  image. Fixed by having `entrypoint.js` explicitly PUT the xar to `/db` and call
  `repo:install-and-deploy-from-db` — the same, actually version-aware upgrade procedure already
  documented (and proven) by hand in `README_TEST_CONTAINER.md` — on every boot, not relying on
  autodeploy at all. The ODD recompile (also moved to run every boot, not just first boot) retries
  a few times: `/api/odd` is gated by `x-constraints` (a group-membership check, not a bad-password
  check — roaster's `auth.xql` returns the same bare "Access denied" 401 either way), and that
  membership doesn't always propagate before `jinks create` returns; the identical request retried
  a few seconds later succeeds.
- **Empty annotation-toolbar buttons** (no person/place/save/undo/... icons, just blank pills) —
  a separate bug from the XQDY0025 crash, only visible once that crash was fixed enough to reach
  the toolbar at all. The buttons' `<svg><use href="#person-fill">` markup needs the icon
  sprite's `<symbol>` defs present somewhere in the same document. `annotate`'s own
  `templates/pages/annotate.html` frontmatter already declared `theme.icons:
  ["annotate-icons.svg"]`, the convention `base10`'s `templates/layouts/base.html` is meant to
  consume via `[% for $icons in $context?theme?icons?* %][% include ... %][% endfor %]` (the
  same pattern the sibling `metadata-editor` profile uses successfully) — but this app's
  actually-deployed `base10` has no such loop at all (confirmed by fetching the live
  `templates/layouts/base.html`: it `[% include %]`s `menu.html`/`toolbar.html`/
  `footer-mobile.html`, nothing icon-related), so declaring `theme.icons` anywhere had no effect.
  Fixed pragmatically, matching this project's established pattern for base10 drift: `annotate`'s
  own `content-top` template now directly `[% include "resources/css/annotate-icons.svg" %]`s
  the sprite itself, independent of whether the app's base10 supports the `theme.icons`
  mechanism. (The `config.json` `theme.icons` declaration was left in place too — harmless, and
  correct for any base10 that *does* implement the loop.)
- **The entire annotation-editor side panel looked broken once it actually rendered** —
  misshapen "cards" with no visible border, invisible-looking form labels, a "minuscule" save
  icon, everything cramped into far too little vertical space. **Not Docker-specific** — confirmed
  by reproducing it outside Docker too, in a plain dev-container app on the stock base image, then
  applying and re-verifying the same fix there before rebuilding the Docker image. Root cause: a
  CSS specificity collision. `annotate.css`'s `fx-fore fx-group { display: grid; ... }` rule
  (specificity `0,0,2`, two type selectors) is what drives every card's grow/shrink animation and
  layout — but `@jinntec/fore`'s own CDN-loaded `fore.css` has a generic `[relevant] { display:
  block; }` rule (specificity `0,1,0`, an attribute selector) that Fore itself stamps onto every
  currently-visible element (`relevant=""`). Attribute selectors always outrank pure type
  selectors regardless of source order, so *every* visible `fx-group` silently fell back to plain
  block flow instead of the intended grid layout — confirmed directly via Playwright:
  `getComputedStyle` on a "card" `fx-group` showed `display: block`, `height: 36px`, while its own
  child `<header>` measured `54px` tall (overflowing its collapsed parent). This has nothing to do
  with this project's Docker packaging - it's been latent in the `annotate` profile itself since it
  started depending on `forms`/Fore (2026-02-18); the automated GUI regression tests only ever
  assert functional behavior (request URLs, form field values), never checked CSS, so nobody
  noticed until a real screenshot was taken. Fixed by raising the selector's specificity to match:
  `fx-fore fx-group[relevant] { display: grid; ... }` (specificity `0,1,2`) — wins the cascade
  regardless of stylesheet load order, and doesn't touch the (already-correct) hidden/`nonrelevant`
  case at all since that selector simply won't match those elements.
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
- **Entity mentions in the annotate view aren't clickable at all** (no `.annotation`/
  `.annotation-authority` styling or click handlers anywhere on the page, even though the raw TEI
  markup and manifest look fine). Root cause: `base10`'s own app-generation hook
  (`teip:custom-odd-install` in its `setup.xql`) unconditionally stamps a **blank** starter ODD
  over any profile-declared-but-not-yet-present `resources/odd/<name>.odd` on `jinks create` —
  independent of `extends` order or whether `jinntap` is included — discarding every
  `cssClass="annotation ... authority"` rule in `annotate`'s `annotations.odd` before the app is
  even usable once. The Jinks-registered profile copy stays correct throughout; only the
  generated app's own copy is affected. Fixed the same way as the `tei-publisher-lib`/roaster
  fixes below: `entrypoint.js`'s `restoreAnnotationsOdd()` re-PUTs the real file right after
  `createApp()`, before the ODD recompile step.
- **`GET /api/reconcile/v0.2` (or any path merely *starting with* a declared route) wrongly
  matches that route** instead of 404ing — `router:create-regex` in the bundled `roaster` package
  built path-matching regexes anchored only at the start, never the end (upstream issue
  eeditiones/roaster#122). This project's `tei-publisher-roaster` checkout already carries the fix
  (bumped to `1.13.0`), but — same class of bug as the `tei-publisher-lib` one above — the image
  never actually baked it in. Fixed identically: a `roaster-builder` Dockerfile stage plus
  `entrypoint.js`'s `installRoaster()`, called right after `installTeiPublisherLib()`.

All were re-verified together against a fully fresh `podman build` + `podman run` (no reused
layers beyond the base image, no persisted volume): i18n resources serve real translations, the
annotate view has no `XQDY0025`, the ODD recompile succeeds, a Playwright check confirms `fx-fore`
upgrades correctly with none of the raw-markup strings visible in the rendered page, a screenshot of
the annotation toolbar shows real icons instead of blank buttons, `annotations.odd`'s `cssClass`
rules survive app creation, and `GET /api/reconcile/v0.2` 404s instead of matching the manifest
route. Full regression (25 XQSuite + 39 Cypress API + 6 Cypress GUI + `cors-check.sh` + a real Match
round-trip against both the 0.2 and 1.0-draft local testbenches) is green against this image as of
`0.1.2`.

One more log line is expected and **not** a bug: `pb-login`'s own `_checkLogin` component
(`tei-publisher-components/src/pb-login.js`) issues an unauthenticated status-check POST to
`/api/login/` on every page load to find out whether a session already exists; a `401 Wrong user
or password` from that specific probe is normal even while actually logged in via a real session
cookie elsewhere - it isn't evidence of a login problem.

## Known limitations / next steps

- Setup happens at container *first boot*, not baked into the image layers — simpler and more
  robust given the base image has no shell to run setup *during* `docker build`, at the cost of
  a slower first start. True build-time baking is possible (e.g. via a `docker commit`-based
  build step outside plain Dockerfile `RUN` semantics) but wasn't attempted here; flag if you
  want it.
- `tei-publisher-components`'s committed `package-lock.json` has drifted from `package.json` in
  this checkout — the Dockerfile uses `npm install`, not `npm ci`, to tolerate that. Regenerating
  a clean lockfile (and switching to `ci`) would make builds more reproducible.
