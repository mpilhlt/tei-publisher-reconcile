# TEI Publisher Reconciliation

A [Reconciliation Service API](https://reconciliation-api.github.io/specs/)
implementation for [TEI Publisher](https://teipublisher.com/) v10, plus a matching client
integration for looking up and linking named entities (people, places, organizations, works)
against any reconciliation service — this one included — while annotating a TEI document.

- **Server**: a new Jinks profile, [`reconcile/`](reconcile), implementing both the
  **0.2** and **1.0-draft** versions of the spec from a single endpoint. By default it
  reconciles against TEI Publisher's own person/place/organization/work authority
  registers, but that's just the shipped configuration — one file,
  [`modules/reconcile-config.xql`](reconcile/modules/reconcile-config.xql), lets
  you swap in a custom entity-lookup function, scoring, and preview per type, so it's not
  tied to those registers or even to TEI Publisher's own data model. It also supports the
  optional `/preview`, `/suggest/*`, and data-extension (`/extend`) services on top of the
  mandatory match/reconcile endpoint.
- **Client**: an (updated) extension of TEI Publisher's `annotate` profile that wires a
  reconciliation-service connector into the entity-authority editor — click a `persName`/
  `placeName`/`orgName`/`term`/`bibl` mention, search a reconciliation service by name, and
  link the mention to the returned candidate. This is configured mostly in the
  `<pb-authority-lookup>` section of the `templates/pages/annotate-tei.html` and
  `modules/annotations/tei-annotation-config.xqm` files coming with TEI Publisher's
  `annotate` profile (cf. the regular
  [TEI Publisher documentation](https://teipublisher.com/doc/annotations.xml)).
- **Demo image**: a self-contained container with both baked in, so you can try the whole
  thing without setting up a TEI Publisher/Jinks development environment yourself — see
  below.

## Try the demo

The published image bundles a TEI Publisher v10 instance, the `reconcile` profile, and the
patched `annotate` client, with sample data (a small corpus of Karl Barth's sermons and their
person/place authority records) already loaded.

```bash
podman run -d --name tp-reconc-demo -p 8080:8080 \
  ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:latest
# or: docker run -d --name tp-reconc-demo -p 8080:8080 ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:latest
```

The first boot takes 30–90 seconds longer than a normal restart — that's the container
generating the app and deploying the profiles. Watch it come up with:

```bash
podman logs -f tp-reconc-demo
# or: docker logs -f tp-reconc-demo
```

Once you see `Ready:`, the app is at:

```
http://localhost:8080/exist/apps/tp-reconc
http://localhost:8080/exist/apps/tp-reconc/api/reconcile
```

See "Exploring the demo" below for what to actually try once it's up.

No volume is mounted by default, so a removed container loses all state and a fresh one
always starts from the same pristine demo data — see [`docker/README.md`](docker/README.md)
for persistence, the environment variables the image accepts (including a self-hosted vs.
CDN switch for the web-component bundle), and how to build the image yourself.

## Exploring the demo

**As a reconciliation *server*, from OpenRefine:** in OpenRefine, open or create a project
with a column of names (a mix of well-known ones and the demo's own — e.g. "Barth" — works
well), then ***\<Name column\>* ▾** → **Reconcile** → **Start reconciling...** → **Add
Standard Service...** → paste
`http://localhost:8080/exist/apps/tp-reconc/api/reconcile?version=0.2`, pick a type, and
**Start Reconciling**.

> ***Note** that OpenRefine currently (at v3.10.0) has better support for the 0.2 version of
the Reconciliation API protocol, so use the `?version=0.2` query parameter* (without it,
TEI Publisher serves v.10-draft responses).

If you have other columns in your OpenRefine project that might help disambiguate entities
(e.g. gender, profession etc.), you can specify them in "Also use relevant details from other
columns" when reconciling (but the demo app does not happen to have ambiguous entries where
this would be needed). When you are happy with the reconciled entities, try adding TEI
Publisher entity URLs or identifiers as new columns in OpenRefine with
***\<Name column\>* ▾** → **Reconcile** → **Add column with URLs of matched entities...**,
or **Add entity identifiers column...**.
You can add even more data served by TEI Publisher with ***\<Name column\>* ▾** → **Edit column** →
**Add columns from reconciled values...**, which will open a property picker dialogue

**As a reconciliation *client*, in TEI Publisher's annotation editor:** open the demo app at
<http://localhost:8080/exist/apps/tp-reconc>, navigate to a document, and use the annotate
editor. Click an already-linked entity mention to see a live preview (biography, dates, ...)
rendered from its linked authority record, not just a bare id. Select an untagged mention,
and push the person button to tag it as an entity (*person* being the only type of entity
that has a `ReconciliationService` authority db connector configured in the demo app). In the
"Search/edit reference" panel that appears, matching entries from both local register and
gnd persons will be combined. If a direct match in the register is found, it takes precedence
over reconciliation lookups (the `local` badge on the right), but you can modify the string
that is being searched for and when only a reconciliation query returns a result (because it
can do fuzzy matching), the reconciliation interface to the local register kicks in: The badge
changes to `Reconciliation` and the entry will be a hyperlink to the entity's view - which in
this case happens to be provided by the app itself. Picking a candidate (with the "chain links
button") tags the selected string and writes the entities identifier and, depending on the
configuration, additional properties/attributes into the markup.

**Against the spec itself:** point the official
[reconciliation-api test bench](https://reconciliation-api.github.io/testbench/1.0/) (or a
locally-run copy — see [`README_MANUAL_TESTING.md`](README_MANUAL_TESTING.md)) at the same
`/api/reconcile` URL to exercise match, suggest, preview, and data-extension directly
against the spec's own reference client.

## Publishing the image

```bash
# podman login ghcr.io -u <github-username> --password-stdin   # PAT needs write:packages
podman tag localhost/tp-reconc-demo:latest ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:latest
podman tag localhost/tp-reconc-demo:latest ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:<version>
podman push ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:latest
podman push ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:<version>
```

## Repository layout

| Path | What it is |
|---|---|
| [`reconcile/`](reconcile) | The Jinks profile implementing the reconciliation server. |
| [`docker/`](docker) | The self-contained demo image: `Dockerfile`, entrypoint, config. |
| [`skills/`](skills) | An agent skill automating the profile-authoring/test/deploy loop used to build this project. |
| `README_TEST_CONTAINER.md` | Setting up a local podman/Jinks dev environment from scratch. |
| `README_MANUAL_TESTING.md` | Hands-on routines for verifying the server and client both work. |

## Forked & patched dependencies

This project's client side, and a few of TEI Publisher v10's own building blocks, needed
real fixes and new features (see each fork's commit history for details, they are listed
below). None of these forks are vendored into this repository — see `.gitignore` — they're
cloned locally as siblings of this repo for development; see `AGENTS.md`'s "References"
section for exact paths. **Once things have settled, the intent is to submit pull requests
upstream** for each fork's changes.

**Note:** each fork's link below points at its `feature/reconcile` branch specifically,
*not* the fork's default branch — every fork's default branch on GitHub still just
mirrors its upstream's `main`/`master` unmodified, so browsing to the bare repo URL
(without a branch) will not show the patches described here.

| Fork | Upstream | Branch(es) | What's patched |
|---|---|---|---|
| [tei-publisher-jinks](https://github.com/mpilhlt/tei-publisher-jinks/tree/feature/reconcile) | [eeditiones/jinks](https://github.com/eeditiones/jinks) | `feature/reconcile` | The `annotate` profile's reconciliation-client wiring (connector config, field mapping, `keyMap` fixes) and a `forms` profile fix (missing `features.forms.enabled`). Does **not** yet include a fix for the `base10` ODD-stub bug below — that's still only worked around downstream. |
| [tei-publisher-components](https://github.com/mpilhlt/tei-publisher-components/tree/feature/reconcile) | [eeditiones/tei-publisher-components](https://github.com/eeditiones/tei-publisher-components) | `feature/reconcile` | `pb-authority-lookup`'s connectors (`ReconciliationService`, GND, GeoNames), 0.2/1.0-draft protocol support, several client-side fixes. |
| [tei-publisher-lib](https://github.com/mpilhlt/tei-publisher-lib/tree/feature/reconcile) | [eeditiones/tei-publisher-lib](https://github.com/eeditiones/tei-publisher-lib) | `feature/reconcile` | One fix: `model:map()` wrote a duplicate `@data-tei` attribute when one already existed. |
| [tei-publisher-roaster](https://github.com/mpilhlt/tei-publisher-roaster/tree/feature/reconcile) (roaster) | [eeditiones/roaster](https://github.com/eeditiones/roaster) | `feature/reconcile` | A route-matching fix (unanchored regex; trailing-slash tolerance). |
| [tei-publisher-app](https://github.com/mpilhlt/tei-publisher-app/tree/feature/reconcile) | [eeditiones/tei-publisher-app](https://github.com/eeditiones/tei-publisher-app) | `feature/reconcile` | Docs only — the `reconcile` profile's documentation pages, since that's where TEI Publisher's public docs site content actually lives. |
| [reconc-testbench](https://github.com/mpilhlt/reconc-testbench) ([upstream `testbench-0.2` branch](https://github.com/reconciliation-api/testbench/tree/testbench-0.2)) | [reconciliation-api/testbench](https://github.com/reconciliation-api/testbench) | `master` (1.0-draft UI, and the fork's default branch), `testbench-0.2` (0.2 UI, used unmodified straight from upstream — never pushed to the fork) | Fixed the Extend tab's results table, which only ever handled the pre-1.0 `rows` shape. |
| [tei-publisher-jinks-cli](https://github.com/mpilhlt/tei-publisher-jinks-cli/tree/feature/reconcile) (jinks-cli) | [eeditiones/jinks-cli](https://github.com/eeditiones/jinks-cli) | `feature/reconcile` | Unmodified — used as the `jinks` CLI for local dev; the demo image installs the published npm package instead. |
| [tei-publisher-jinks-templates](https://github.com/mpilhlt/tei-publisher-jinks-templates/tree/feature/reconcile) (jinks-templates) | [eeditiones/jinks-templates](https://github.com/eeditiones/jinks-templates) | `feature/reconcile` | Unmodified — reference only. |
| [reconc-specs](https://github.com/mpilhlt/reconc-specs) | [reconciliation-api/specs](https://github.com/reconciliation-api/specs) | `master` (the fork's default branch) | Unmodified — JSON Schemas and examples used for conformance testing. |

**What breaks without the `tei-publisher-lib`/`roaster` fixes** — the two forks above with the
smallest, most surgical diffs from upstream. Both fixes are also documented as code comments at
the exact line changed, not just here and in commit messages:

- `tei-publisher-lib`, `content/model.xql`, `model:map()`: without the guard added in
  [`35cb740`](https://github.com/mpilhlt/tei-publisher-lib/commit/35cb740) (comment added in
  [`cd2379c`](https://github.com/mpilhlt/tei-publisher-lib/commit/cd2379c)), any request that
  renders a document through `annotate`'s track-ids mode — e.g.
  `GET /api/document/{id}?user.track-ids=yes`, which `annotate-tei.html`'s
  `<pb-param name="track-ids" value="yes">` sends on every page load — throws
  `err:XQDY0025: element has more than one attribute 'data-tei'` and the annotate view 500s.
  Reproduced by `cy.visit()`ing any annotate URL in
  [`reconcile/test/cypress/e2e/gui/annotate-reconciliation.cy.js`](reconcile/test/cypress/e2e/gui/annotate-reconciliation.cy.js)
  (e.g. `/sermons/27004.xml?template=annotate-tei.html&odd=annotations&view=single`).
- `tei-publisher-roaster`, `content/router.xql`, `router:create-regex()`: without the end-anchor
  added in [`03c0b31`](https://github.com/mpilhlt/tei-publisher-roaster/commit/03c0b31) and the
  trailing-slash tolerance added in
  [`4d6bf1e`](https://github.com/mpilhlt/tei-publisher-roaster/commit/4d6bf1e) (comment added in
  [`426d580`](https://github.com/mpilhlt/tei-publisher-roaster/commit/426d580)), any request path
  that merely *starts with* a declared route wrongly matches that route instead of 404ing — e.g.
  `GET /api/reconcile/v0.2` (a nonexistent path — not the `?version=0.2` query param the manifest
  actually uses) wrongly returns the bare `/api/reconcile` route's manifest instead of a 404.
  Covered by the container regression run in
  [`docker/README.md`](docker/README.md#verified-end-to-end) ("`GET /api/reconcile/v0.2` 404s
  instead of matching the manifest route"), not currently a standalone Cypress assertion.

**Known gap, not yet fixed upstream:** `base10`'s own `setup.xql` (present unmodified in the
`tei-publisher-jinks` fork, i.e. this bug is real in `eeditiones/jinks` too, not just the demo
image's base) unconditionally overwrites any profile-declared `"odds"` entry with a **blank**
starter ODD on a fresh `jinks create`, regardless of whether the declaring profile — `annotate`
here — already ships real content at that path. This silently discards every
`cssClass="annotation ... authority"` rule `annotations.odd` defines, which is what makes entity
mentions clickable in the annotation editor at all. **The only fix that exists today is a
workaround in this repo's own `docker/entrypoint.js`** (`restoreAnnotationsOdd()`, re-PUTs the real
file right after app creation) — *not* a fix in the `tei-publisher-jinks` fork itself, so a PR from
that fork as it stands would **not** resolve this for anyone using Jinks directly (outside this
project's Docker automation). Properly fixing `base10/setup.xql` there is deliberately deferred:
doing so would also mean revisiting whether `docker/entrypoint.js`'s workaround becomes redundant
(and either removing it or keeping it as a defensive no-op), then rebuilding and re-running the
full container regression suite against that change — real, but out of scope for now. Full
investigation and root-cause details in [`docker/README.md`](docker/README.md)'s troubleshooting
log.

## Conformance

The server is tested against the
[reconciliation-api JSON Schemas](https://github.com/reconciliation-api/specs) for both spec
versions on every change (via Cypress + [`cypress-ajv-schema-validator`](https://www.npmjs.com/package/cypress-ajv-schema-validator)),
and against a locally-run copy of the
[reconciliation-api test bench](https://github.com/reconciliation-api/testbench) — both the
0.2 and 1.0-draft UIs — as the final conformance gate before any change is considered done.
See `AGENTS.md` for the full development workflow.

## License

Licensed under the [GNU General Public License v3.0](LICENSE) or later.

Copyright (C) 2026 Max Planck Institute for Legal History and Legal Theory.
