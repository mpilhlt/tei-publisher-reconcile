# Manual testing guide — Reconciliation Service profile

Quick, hands-on routines to confirm both reconciliation aspects of this project actually
work: **(A)** the `reconcile` profile as a server, and **(B)** the `annotate` editor's
Reconciliation Service connector as a client. For a quicker, higher-level tour instead of
exhaustive verification, see the "Exploring the demo" section of the main
**[`README.md`](README.md)**.

Everything below assumes the local podman container is up and `tp-reconc` is generated
with the extended config (`annotate`/`upload`/`jinntap`/`theme-base10` on top of
`reconcile`). If it isn't — or `jinks`/Node aren't cooperating — see
**[`README_TEST_CONTAINER.md`](README_TEST_CONTAINER.md)** first (covers `up.sh`, app
creation/regeneration, and troubleshooting).

```bash
BASE=http://localhost:8080/exist/apps/tp-reconc/api/reconcile
```

The automated regression suite (25 XQSuite + 45 Cypress tests, both spec versions and
both server/client aspects) is the authoritative check — this guide is for when you want
to see it work yourself, or debug something the automated suite doesn't cover (a live
OpenRefine session, the official testbench UI).

---

## A. Server: curl / Insomnia smoke test

```bash
curl -s "$BASE" | jq .                        # 1.0-draft manifest (default)
curl -s "$BASE?version=0.2" | jq .             # 0.2 manifest

# reconcile
curl -s -X POST "$BASE" -H 'Content-Type: application/json' -d '{
  "queries": [{ "type": "person", "conditions": [
    { "matchType": "name", "propertyValue": "Goethe" }
  ]}]
}' | jq .

# suggest (type-ahead)
curl -s "$BASE/suggest/entity?prefix=Goe" | jq .

# preview
curl -s "$BASE/preview?id=kbga-actors-136"     # HTML fragment, or open in a browser

# data extension
curl -s -X POST "$BASE/extend" -H 'Content-Type: application/json' -d '{
  "ids": ["gnd-119442086"], "properties": [{ "id": "gnd" }, { "id": "occupation" }]
}' | jq .
```

Expect: real candidates from this app's own demo register data (not empty results, not a
500). Full request/response shape reference and more examples: `reconcile/doc/README.md`.

## B. Server: official conformance testbench

The authoritative spec-conformance check — a real, spec-authored UI, not something we
built.

```bash
cd reconc-testbench && npm install && npm start        # 1.0-draft, http://localhost:3000
# for 0.2: a second checkout on branch testbench-0.2, or `git worktree add`
```

Paste `http://localhost:8080/exist/apps/tp-reconc/api/reconcile` into the testbench's
endpoint field. Expect: green checkmarks across Manifest/Reconcile/Suggest/Preview/Extend
for both versions.

## C. Client: the annotate editor's Reconciliation Service connector

```
http://localhost:8080/exist/apps/tp-reconc/sermons/27004.xml?template=annotate-tei.html&odd=annotations&view=single
```

(Reached in normal use via a document's **Admin → Annotate Document** menu, not a
bookmarkable standalone URL.)

1. Click an already-tagged person entity (e.g. "Thurneysen") → its real preview should
   appear (biographical text fetched live), not "Entity not found".
2. Click the pencil icon → a search panel opens; type a query → candidates appear from
   **both** the local register (badge "local") and GND (badge "GND") in one federated
   list.
3. Select a candidate via its "link to" button → the entity's `@ref`/`@key`/extend-fetched
   attributes update (inspect the document source, or reload and repeat step 1).

Expect: search requests go to `.../tp-reconc/api/reconcile`, never an external host
(check the browser's network tab if in doubt — a misconfigured `connector` attribute
silently falls back to `api.metagrid.ch` with no error, the one regression this whole
flow specifically guards against).

## D. OpenRefine, end to end

1. Open/create an OpenRefine project with a text column of names (e.g. "Goethe",
   "Dantiscus", "Madrid").
2. Column ▾ → **Reconcile → Start reconciling...** → **Add Standard Service...** → paste
   `http://localhost:8080/exist/apps/tp-reconc/api/reconcile?version=0.2` (**use the
   `?version=0.2` URL, not the bare one** — see the callout below). Pick a type, **Start
   Reconciling**.
3. Expect: candidates with scores, zero errors on a real batch.
4. To disambiguate via a **property condition from another column**: in the same dialog,
   under "Also use relevant details from other columns," click into the "As property" box
   for that column and type a few characters — a real autocomplete dropdown should appear
   (verified live 2026-08-06 against OpenRefine 3.10.0, using a custom `initials` person
   property added to `reconcile-config.xql` for the test: typing "Ini" showed "Initials" in
   the dropdown, selecting it and reconciling produced correct, scored matches for both
   test rows). If nothing appears while typing and "Start reconciling" then refuses with
   "Column 'X' is not mapped," you're pointed at the bare (1.0-draft) endpoint — switch to
   `?version=0.2` (see below).
5. For **"Add columns from reconciled values"** (data extension): **Edit column → Add
   columns from reconciled values...**, pick a property (gnd/gender/occupation for person,
   geonames/wikidata for place). No second service needed if you already reconciled with
   the `?version=0.2` URL in step 2.

**Why `?version=0.2`, not the spec-preferred 1.0-draft URL:** verified live (real browser,
real OpenRefine 3.10.0, network-captured) that OpenRefine's own client only wires up its
live property-autocomplete — both for step 4's column-as-property picker *and* for the
"Add columns from reconciled values" property search — against the classic 0.2-shaped
`suggest.property` manifest object (`service_url`/`service_path`). The 1.0-draft manifest's
spec-compliant `suggest.property: true` isn't understood by either of OpenRefine's pickers:
typing produces no request at all for the first, and OpenRefine falls back to its own
hardcoded legacy default (`https://www.googleapis.com/freebase/v1/search?...`) for the
second — neither is a bug in this server. This isn't limited to data extension as
previously documented here; it affects the reconciliation dialog's own property-condition
picker identically, and one `?version=0.2` service used throughout (not a second service
added just for extend) resolves both at once.

## Known, currently-open gaps

- Selecting a candidate to **re-link an already-annotated span** via a forced/scripted
  click updates the on-page form but hasn't been confirmed to always persist to the saved
  document on reload — manual, unscripted use works; flagged as a test-rigor gap, not a
  confirmed product bug.
- Extending a property via an arbitrary cross-document XPath (e.g. "every document URL
  where this entity occurs") isn't supported by the current `properties` config shape —
  the shipped `avg-title-length` example property demonstrates the closest supported
  pattern (a computed, corpus-querying property), see `reconcile/doc/README.md`.

## Full regression (automated)

```bash
# XQSuite (25 tests)
skills/teipublisher-reconciliation-testing/scripts/ci-run-xqsuite.sh tp-reconc

# Cypress: API (39) + annotate GUI (6), from the generated-app checkout
cd tp-reconc-checkout && npx cypress run \
  --spec "test/cypress/e2e/api/reconcile.cy.js,test/cypress/e2e/gui/annotate-reconciliation.cy.js"
```
