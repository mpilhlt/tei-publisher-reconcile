# Manual testing & exploration guide — Reconciliation Service profile

This is a hands-on companion to `AGENTS.md`/`CLAUDE.md` (which covers the automated
testing workflow). Use this when you want to **poke at the service yourself** — in a
browser, with curl/Insomnia, or from OpenRefine — and at the bottom there's a **demo
script** for showing the profile off in a presentation.

Everything below assumes the local podman container is up and the demo app is
generated (see "Where things stand" below for the current state).

```bash
BASE=http://localhost:8080/exist/apps/tp-reconc/api/reconcile
```

If the container isn't running, `tp-reconc` doesn't exist yet, or `jinks`/Node aren't
cooperating, stop here and see **[`README_TEST_CONTAINER.md`](README_TEST_CONTAINER.md)**
first — it covers `up.sh`, app creation/regeneration, and troubleshooting (disk-full →
read-only DB, Node version, CORS, crashed container, full reset) in detail. Short version:
`skills/teipublisher-reconciliation-testing/scripts/up.sh` (waits for readiness), then if
needed `jinks update tp-reconc -s http://localhost:8080/exist/apps/jinks -u tei -p simple`
(needs Node ≥22 — `export NVM_DIR="$HOME/.nvm"; source "$NVM_DIR/nvm.sh"; nvm use 22`).

---

## Where things stand right now

*(Written 2026-07-18, end of the production-hardening pass — update this section as
work continues so a future session/you-after-a-break can reorient in 30 seconds.)*

- All four planned follow-ups are **done and pushed**: (1) CI for this repo, (2) local
  testbench re-run after the matching rewrite, (3) *(attempted 2026-07-23, see below)*,
  (4) production-hardening (request-size caps + docs).
- **2026-07-23 manual exploration session:** finally clicked through both the annotation
  editor and OpenRefine (see sections B3/C below and "Known gaps"). Found: a real core
  TEI Publisher bug (`XQDY0025` duplicate `data-tei` attribute) blocking the annotate
  view, a theme/layout issue (fixed by switching to the "neutral" palette), an
  app-config gap (the annotate editor needs `upload`/`jinntap`/`annotate` on top of the
  API-only config), an unresolved connector-wiring bug (the annotation editor's
  Reconciliation connector queries `metagrid.ch` instead of the local endpoint), and —
  most important — a real, previously-uncaught **batch reconciliation bug** surfaced by
  OpenRefine (5 matches / 88 errors on a real column). None of this was caught by
  Cypress/the testbench, since both only exercise single/small-batch queries.
- **2026-07-24 follow-up:** every problem found during manual testing is now fixed and
  verified — the OpenRefine batch bug (§C), the `XQDY0025` annotate-view crash (fixed
  upstream in `tei-publisher-lib` 6.1.1, §B3), the incomplete `annotation-config.xqm`
  (turned out to be session-specific stale state, not reproducible from a fresh app),
  and the Reconciliation connector silently falling back to `metagrid.ch` (root cause:
  `createConnectors()`'s unrecognized-connector-name fallback — needs the exact
  `connector="ReconciliationService"`). All fixes verified directly against the actual
  crash/bug code paths, not just "page loads" — including a new automated GUI test,
  `reconcile/test/cypress/e2e/gui/annotate-reconciliation.cy.js`, covering the full tag
  → search → select flow in a real browser. `tp-reconc` is currently running the
  extended config (`annotate`/`upload`/`jinntap`/`theme-base10` active) — see §B3/§2c in
  `README_TEST_CONTAINER.md` if you need to reproduce this state after a reset.
- Latest commits: `tei-publisher-reconcile@54389e8` (main), `tei-publisher-app@753f1ad6`
  (feature/reconcile), `tei-publisher-jinks@0045e4a7` (feature/reconcile) — all pushed,
  all three working trees clean.
- CI (`tei-publisher-reconcile`, GitHub Actions) is green on the latest push
  (`gh run list --repo mpilhlt/tei-publisher-reconcile`).
- Full regression as of the last run: **25 XQSuite + 31 Cypress tests green**, CORS
  clean, all re-verified after a plain `jinks update --all` (no reliance on leftover
  DB state).
- The `teipub` podman container has been running for a while — if `curl $BASE` doesn't
  respond, check `podman ps` / restart it. (We hit the host disk filling up and eXist
  going read-only once this session — see the `local-env-node-podman` memory / just
  check `podman system df` and `df -h /home` if PUTs start failing with a bare 500 and
  an empty body.) Full setup/troubleshooting steps now live in
  **[`README_TEST_CONTAINER.md`](README_TEST_CONTAINER.md)** — use that instead of
  re-deriving container commands from scratch.
- No dev servers (testbench, es-dev-server) are running by default — start them
  yourself per the sections below when you need them.

---

## A. curl / Insomnia cheat sheet

Everything here is plain HTTP — paste any of these into Insomnia (New Request →
paste the URL; for POSTs set Body → JSON and paste the payload) exactly as shown.
Every example below uses **real demo data** and has been verified live this session.

### Manifest

```bash
curl -s "$BASE" | jq .                       # 1.0-draft (default)
curl -s "$BASE?version=0.2" | jq .            # 0.2
```

The 1.0-draft manifest's `preview.url` and `view.url` are absolute — you can open
them directly in a browser (see section B).

### Reconcile — 1.0-draft (`POST /api/reconcile` or `/api/reconcile/match`)

Plain name match:

```bash
curl -s -X POST "$BASE" -H 'Content-Type: application/json' -d '{
  "queries": [{ "type": "person", "conditions": [
    { "matchType": "name", "propertyValue": "Goethe" }
  ]}]
}' | jq .
```

Typo-tolerant fuzzy match (misspelled, still finds Goethe with a nonzero score):

```bash
curl -s -X POST "$BASE" -H 'Content-Type: application/json' -d '{
  "queries": [{ "type": "person", "conditions": [
    { "matchType": "name", "propertyValue": "Goehte" }
  ]}]
}' | jq .
```

Disambiguate with a **required property condition** (name + gender — this excludes
Goethe when you ask for `"female"`, keeps + boosts him for `"male"`):

```bash
curl -s -X POST "$BASE" -H 'Content-Type: application/json' -d '{
  "queries": [{ "type": "person", "conditions": [
    { "matchType": "name", "propertyValue": "Goethe" },
    { "matchType": "property", "propertyId": "gender", "propertyValue": "male",
      "required": true, "matchQualifier": "ExactMatch" }
  ]}]
}' | jq .
```

Direct **id** lookup (score is always exactly 100):

```bash
curl -s -X POST "$BASE" -H 'Content-Type: application/json' -d '{
  "queries": [{ "conditions": [{ "matchType": "id", "propertyValue": "kbga-actors-136" }] }]
}' | jq .
```

**Property-only** query — no name at all, matches purely on a known GND id (mirrors
the spec's own "no query string" example verbatim):

```bash
curl -s -X POST "$BASE" -H 'Content-Type: application/json' -d '{
  "queries": [{ "type": "person", "conditions": [
    { "matchType": "property", "propertyId": "gnd",
      "propertyValue": "https://d-nb.info/gnd/119442086", "matchQualifier": "ExactMatch" }
  ]}]
}' | jq .
```

Batch (multiple queries in one request — try mixing person/place):

```bash
curl -s -X POST "$BASE" -H 'Content-Type: application/json' -d '{
  "queries": [
    { "type": "person", "conditions": [{ "matchType": "name", "propertyValue": "Goethe" }] },
    { "type": "place", "conditions": [{ "matchType": "name", "propertyValue": "Madrid" }] }
  ]
}' | jq .
```

### Reconcile — 0.2 (`POST /api/reconcile`, id-keyed)

```bash
curl -s -X POST "$BASE" -H 'Content-Type: application/json' -d '{
  "q0": { "query": "Goethe" }
}' | jq .

# the flat "properties" array works too (0.2's equivalent of a property condition):
curl -s -X POST "$BASE" -H 'Content-Type: application/json' -d '{
  "q0": { "properties": [{ "pid": "gnd", "v": "https://d-nb.info/gnd/119442086" }] }
}' | jq .

# classic application/x-www-form-urlencoded convention (what the 0.2 testbench itself sends):
curl -s -X POST "$BASE" --data-urlencode 'queries={"q0":{"query":"Goethe"}}' | jq .
```

### Suggest (auto-complete, shared shape across both spec versions)

```bash
curl -s "$BASE/suggest/entity?prefix=Dant" | jq .           # -> Dantiscus, Ioannes (gnd-119442086)
curl -s "$BASE/suggest/entity?prefix=Goe&type=person" | jq .
curl -s "$BASE/suggest/property?prefix=&type=person" | jq . # -> gnd, occupation, gender, note
curl -s "$BASE/suggest/type?prefix=" | jq .                 # -> person, place, organization, work
```

### Preview & entity view

```bash
curl -s "$BASE/preview?id=kbga-actors-136"                  # HTML fragment — or just open in a browser
curl -si "$BASE/entity/kbga-actors-136" | head -5            # 303 redirect to the real /people/... browse page
```

### Data extension

```bash
# fetch property values for a batch of ids (1.0-draft POST shape)
curl -s -X POST "$BASE/extend" -H 'Content-Type: application/json' -d '{
  "ids": ["gnd-119442086"],
  "properties": [{ "id": "gnd" }, { "id": "occupation" }]
}' | jq .

# classic GET convention (what the 0.2 testbench's "Extend" tab sends)
curl -s "$BASE?extend=%7B%22ids%22%3A%5B%22kbga-actors-136%22%5D%2C%22properties%22%3A%5B%7B%22id%22%3A%22gender%22%7D%5D%7D" | jq .

# 0.2-shaped response (id-keyed rows instead of an array)
curl -s -X POST "$BASE/extend?version=0.2" -H 'Content-Type: application/json' -d '{
  "ids": ["kbga-actors-136"], "properties": [{ "id": "gender" }]
}' | jq .

# what properties are even available to extend, for a type
curl -s "$BASE/extend/propose?type=person" | jq .
```

### Production-hardening caps (see `reconcile/doc/README.md` for the full story)

```bash
# batch > 500 queries -> 400
python3 -c 'import json; print(json.dumps({"queries":[{"query":"x"} for _ in range(501)]}))' \
  | curl -s -X POST "$BASE" -H 'Content-Type: application/json' -d @- -o /dev/null -w '%{http_code}\n'

# an absurd "limit" doesn't error, just gets clamped
curl -s -X POST "$BASE" -H 'Content-Type: application/json' -d '{
  "queries": [{ "conditions": [{ "matchType": "name", "propertyValue": "Goethe" }], "limit": 999999999 }]
}' -o /dev/null -w '%{http_code}\n'
```

---

## B. In the browser

### B1. The official reconciliation-api testbench (most reliable, spec-conformance UI)

This is the same tool used as the project's local conformance gate — a real,
spec-authored UI, not something we built. Two branches, one per spec version:

```bash
cd reconc-testbench
npm install         # first time only
npm start           # 1.0-draft UI, http://localhost:3000 (vite)
```

For the 0.2 UI, in a **second checkout or after `git checkout testbench-0.2`**:

```bash
cd reconc-testbench && git checkout testbench-0.2 && npm install && npm start
```

Then in the browser, navigate to (URL-encode the endpoint):

```
http://localhost:3000/#/client/http%3A%2F%2Flocalhost%3A8080%2Fexist%2Fapps%2Ftp-reconc%2Fapi%2Freconcile
```

...or just paste `http://localhost:8080/exist/apps/tp-reconc/api/reconcile` into the
testbench's own "endpoint" input field on its landing page — same result, less
URL-encoding. From there you get tabs for **Manifest**, **Reconcile** (type a name,
see live-scored candidates), **Suggest** (type-ahead), **Preview**, and **Extend** —
all driven by typing into real form fields, good for a live audience.

Known limitation (not a bug in our server, confirmed via curl/Cypress earlier): the
**0.2 testbench's Extend tab** has UI automation friction with its typeahead widget —
if it seems stuck, use curl/Insomnia to demo `/extend` instead, or the 1.0-draft
testbench's Extend tab, which works fine.

### B2. Direct URLs (no separate server needed)

```
http://localhost:8080/exist/apps/tp-reconc/api/reconcile                       # manifest JSON in the browser
http://localhost:8080/exist/apps/tp-reconc/api/reconcile/preview?id=kbga-actors-136   # HTML preview fragment
http://localhost:8080/exist/apps/tp-reconc/api/reconcile/entity/kbga-actors-136       # redirects to the real /people/... register page
```

### B3. The annotation editor's Reconciliation Service connector (client side)

**Status (updated 2026-07-23, first real click-through): the click path in is now known
and the layout/profile-set/core-bug blockers have workarounds, but the Reconciliation
connector itself does not yet hit our local endpoint — see the open bug below before
relying on this for a live demo.**

**1. Extended app config required.** The API-only config from `README_TEST_CONTAINER.md`
§2b is *not* enough for the annotation editor — it needs `upload`, `jinntap`, `annotate`,
and `theme-base10` on top of it:
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
Recreate/update the app with this config, and use `-c <file>` explicitly rather than a
bare `jinks update tp-reconc` (see `README_TEST_CONTAINER.md` §2c for why — there's no
separate "apply the theme" step; a bare `update` just re-POSTs whatever config is
*already installed*, which won't include the theme/extra profiles until you push a
config that does). The `"theme"` block matters too — the **default theme renders the
annotate UI unusably**.

**2. Core TEI Publisher bug blocking the annotate view — fixed 2026-07-24, upstream.**
Opening the annotate view used to throw:
```
The request to the server failed.: err:XQDY0025: element has more than one attribute 'data-tei'
[at line 1386 column 21 in module /db/apps/tp-reconc/transform/teipublisher-web.xql]
```
`transform/teipublisher-web.xql` is *compiled output* of TEI Publisher's ODD→XQuery
compiler — the actual bug was in `model:map()`, `tei-publisher-lib/content/model.xql`
(~line 303-314), which unconditionally wrote `attribute data-tei {...}` onto every
tracked element without checking whether one was already present. `tei-publisher-lib`
is a real EXPath library package resolved by semver, so the real fix was a package
release, not a profile edit: patched `content/model.xql` to guard the attribute, bumped
to `6.1.1`, rebuilt the `.xar`, reinstalled it into the running container, and
recompiled every app's ODDs — see `README_TEST_CONTAINER.md`'s matching troubleshooting
entry for the exact commands. Verified: every ODD, including `annotations`, now
recompiles with zero errors.

**A second, separate bug was also fixed 2026-07-24 — now confirmed working end-to-end.**
Adding `annotate`/`upload`/`jinntap` to reach the annotate view first surfaced a
*different*, pre-existing gap: `tp-reconc`'s generated `modules/annotations/
annotation-config.xqm` was missing three functions entirely (`anno:annotations`,
`anno:occurrences`, `anno:fix-namespaces` — 36 lines instead of the full 148). Because
XQuery module imports are resolved eagerly, one missing function broke roaster's
*entire* composed router, taking down every route in the app, including `/api/reconcile`
— not just annotate ones. **Fix:** copied the full, working `annotation-config.xqm` from
the `tp-workbench` demo app (which has a working annotation setup via the "workbench"
blueprint) over `tp-reconc`'s copy:
```bash
echo 'util:binary-doc("/db/apps/tp-workbench/modules/annotations/annotation-config.xqm")' \
  | skills/teipublisher-reconciliation-testing/scripts/ad-hoc-xquery.sh | base64 -d \
  | curl -sS -u tei:simple -X PUT -H "Content-Type: application/xquery" --data-binary @- \
      "http://localhost:8080/exist/rest/db/apps/tp-reconc/modules/annotations/annotation-config.xqm"
```
(fetch via `util:binary-doc` + base64, not a plain string query — eXist's REST XQuery
service XML-entity-escapes `<`/`>` in a returned string result, which would corrupt the
`<persName>`-style element constructors in the source if written out directly; and a
plain REST GET on the live `.xqm` path would *execute* it as a module rather than
returning source.) Verified directly at the code level, not just "no error on page
load": invoked the compiled transform (`pml:transform` in
`transform/annotations-web-module.xql`) with `map { "track-ids": true() }` — the exact
parameter that turns on `model:map`'s `$trackIds` path — against a real document with
tagged entities (`data/sermons/27004.xml`); it returned 43KB of serialized HTML with
123 `data-tei` occurrences and **no error**, which is only possible if no element ever
got a duplicate `data-tei` attribute (construction throws `XQDY0025` immediately, before
serialization, if it does). Full Cypress (36) + XQSuite suites re-confirmed green
afterward.

**Resolved 2026-07-24: the "delegation mechanism" question was a red herring, not a
bug.** Suspected `annotate/config.json`'s templated `features.annotate.configs.tei` →
`tei-annotation-config.xqm` delegation design might be broken for a freshly-composed
app. Tested directly: deleted `tp-reconc` completely (`repo:undeploy` + `repo:remove` +
collection removal — a plain collection delete alone isn't enough, the Jinks server also
tracks apps as installed EXPath packages) and ran `jinks create` from nothing. Result: a
byte-for-byte **working** `annotation-config.xqm` (148 lines, identical to
`tp-workbench`'s), full test suite green, and a clean screenshot of both the register
browse page and the annotate editor rendering real entity-tagged content correctly
(person/place/date/ref highlighting) with no `XQDY0025`, no giant icons.

The actual explanation: the Jinks *server's own* registered `annotate` profile
(`/db/apps/jinks/profiles/annotate/modules/annotations/annotation-config.xqm` — no
`.tpl.` suffix) ships the plain, fully-hardcoded implementation directly, byte-identical
to what `tp-workbench` and a fresh `tp-reconc` both get. The templated
`features.annotate.configs`/`[[ ]]`-marker delegation design lives only in this
project's **local** `./tei-publisher-jinks` git checkout (a fork of upstream
`eeditiones/jinks` kept for reference/potential future work) — nothing in this
project's tooling syncs that checkout's `annotate` profile onto the running Jinks server
(only `profiles/reconcile`, via `ci-bootstrap-profile.sh`, gets that treatment). The
server's copy came bundled with the `existdb/teipublisher:10.0.0` image itself, an
entirely separate, older lineage. **The earlier "missing functions" bug was
session-specific stale state in that one `tp-reconc` app** (accumulated across many
partial creates/updates over a long session), not a reproducible defect — a genuinely
fresh app just works. No fix needed in `tei-publisher-jinks`; nothing to file upstream.

**3. Click path in**, once 1–2 are sorted:
1. Log in, open a document with tagged entities.
2. From the **Admin** dropdown in the top menu, click **"Annotate Document"**. This
   navigates to:
   ```
   http://localhost:8080/exist/apps/tp-reconc/<collection>/<filename>?template=annotate.html&odd=annotations&view=single
   ```
   — not a bookmarkable standalone URL independent of the document; you always go via
   the document viewer's Admin menu, not a direct `annotate.html?doc=...` link.

**4. Root-caused and fixed 2026-07-24: the Reconciliation connector fell back to
Metagrid.** Configuring the `person` authority with a connector pointed at the local
endpoint still queried `https://api.metagrid.ch/search?query=...` instead of
`localhost`. Root cause: `tei-publisher-components/src/authority/connectors.js`'s
`createConnectors()` `switch` on the `connector` attribute has a silent `default` case
that falls back to the unrelated `Metagrid` connector for **any** unrecognized value —
including a very natural typo like `connector="Reconciliation"` instead of the exact,
case-sensitive `connector="ReconciliationService"`. No error, no warning, just silently
the wrong service. Fix: use the exact connector name, plus its `endpoint` attribute:
```xml
<pb-authority connector="ReconciliationService" name="person"
    endpoint="/exist/apps/tp-reconc/api/reconcile" type="person" edit=""/>
```
(replacing the default `connector="Custom"` wrapping a `GND` connector for `person` —
see `templates/pages/annotate.html`). Verified end-to-end in a real browser (Cypress +
Chromium): clicking a tagged person entity → edit icon → the search panel fires a
request that lands on `tp-reconc/api/reconcile` (confirmed via network interception,
not just "no error") → a real candidate from our own demo data is returned and
rendered → selecting it links the entity to that candidate's id. This flow is now
covered by an automated regression test — see
`reconcile/test/cypress/e2e/gui/annotate-reconciliation.cy.js` (also wires the
connector correctly itself in a `before()` hook, so it doesn't depend on this manual
edit having been applied first).

**Developing the client and server together:** by default the browser loads
`tei-publisher-components` from the CDN, so edits to your local checkout (e.g. another
connector class, or a UI tweak) won't show up in `tp-reconc` until you either publish a
new npm version or point the app at a local dev server instead — see
`README_TEST_CONTAINER.md` §2d for the exact `es-dev-server` + app-config recipe.
Confirmed working 2026-07-24: after fixing the "OpenReconcile" badge label in
`tei-publisher-components` locally, pointing `tp-reconc` at the local dev server showed
the updated "Reconciliation" label live, without touching the CDN version at all.

**5. Open question (not yet answered):** how to define an additional extendable
property computed from an XPath over *all documents* — e.g. "every document URL where
this entity occurs." Today's `properties` config entries extract from a single entity
record, not an occurrence index across the corpus. Needs design work; not started.

Falling back to the standalone testbench (B1) or curl (A) is still the safe choice for
a live demo you haven't personally rehearsed end-to-end.

---

## C. OpenRefine

**Status (updated 2026-07-24): the batch bugs found on 2026-07-23 are fixed and covered
by regression tests (see `openrefine_batch_bug` project memory) — re-verify with a real
OpenRefine run when you get the chance, but curl-level repro of every known failure mode
now returns correct, positionally-aligned results instead of 500s or shortened arrays.**

1. Install/open OpenRefine (tested with v3.10.0), create or open any project with a
   text column of names (e.g. a column containing "Goethe", "Dantiscus", "Madrid", ...).
2. Click the column's dropdown ▾ → **Reconcile → Start reconciling...**
3. In the dialog, click **Add Standard Service...** and paste:
   ```
   http://localhost:8080/exist/apps/tp-reconc/api/reconcile
   ```
   (Recent OpenRefine versions auto-detect 1.0-draft from the manifest. If your
   OpenRefine is older / only speaks 0.2, append `?version=0.2` to the URL instead.)
4. Pick a type (Person/Place/Organization/Work) if prompted, click **Start Reconciling**.

**Observed on a real run (2026-07-23): 5 matches, 88 errors** on the reconciled column.
Different cells failed with different messages:
- `No. of recon objects was less than no. of jobs` — OpenRefine's own batch-shape check.
- `HTTP error 500 : Server Error for URL /exist/apps/tp-reconc/api/reconcile`.
- `The reconciliation service returned an invalid response`.

**Root-caused and fixed 2026-07-24** (see `reconcile/modules/reconcile-api.xql`,
`reconc:as-query-map`/`reconc:safe-limit`, and the `openrefine_batch_bug` project
memory). Confirmed live via curl before the fix, in both wire formats: a single
malformed entry anywhere in a batch — a blank cell serialized as JSON `null`, any other
non-object value, or a non-numeric `limit` — either crashed the *entire* HTTP request
with a 500 (`err:XPTY0004`/`err:FORG0001`, since `reconc-cond:normalize-1.0/0.2` and the
`xs:integer` limit cast both require a well-formed input and raised a fatal error on
anything else), or, for the 1.0-draft array shape specifically, silently vanished during
`?*` array-unboxing — XDM arrays *can* hold an empty-sequence member (JSON `null`), and
unboxing simply drops it, shortening `results` and shifting every later query's answer
out of its correct position. That exact mismatch is what OpenRefine's own batch-shape
check flags as "No. of recon objects was less than no. of jobs". The fix makes every
malformed entry degrade to "zero candidates at its original position" instead, for both
wire formats — five new regression tests cover exactly these cases (`reconcile.cy.js`,
describe block "malformed batch entries..."), plus the existing 31 tests and 24 XQSuite
tests were re-verified green, including once after a full `jinks update --all`.
**Not yet re-verified against real OpenRefine itself** — the curl-level repro is fixed,
but re-running the exact failing column through OpenRefine would be good confirmation
next time you have it open.

5. To try data extension: after reconciling, use **Edit column → Add columns from
   reconciled values...** and pick one of the extend properties (gnd/gender/occupation
   for person, geonames/wikidata for place) — this exercises `/extend` exactly like
   the curl examples in section A. *(Not yet re-verified against the batch-error
   findings above — test this on a column where reconciliation actually produced
   matches.)*

This is a good "does it actually work with the real ecosystem tool" check, distinct
from both our own Cypress suite and the spec's own testbench — and this time it already
caught a real bug neither of those had.

---

## Demo script for a presentation

A ~5–8 minute walkthrough that shows the interesting parts, roughly in order of
"impressive but simple" → "impressive and technical":

1. **Manifest** (curl or browser, `$BASE`) — "this is a standard, spec-conformant
   reconciliation service; here's what it advertises." Point out `versions`,
   `suggest`, `extend` — mention both 0.2 and 1.0-draft are supported from the *same*
   endpoint (`?version=0.2` switches it).
2. **Live reconcile with a typo** (`"Goehte"` → finds Goethe with a nonzero score) —
   shows fuzzy/typo-tolerant matching isn't just naive substring matching.
3. **Disambiguation with a property condition** — same "Goethe" name query, once with
   `gender: female` (excluded — zero candidates) and once with `gender: male` (kept,
   *and* boosted above the name-only score). This is the concrete "reconcile more
   columns as properties" feature OpenRefine users actually rely on.
4. **Property-only query, no name at all** — reconcile purely by a known GND URI.
   Good line: "you don't even need a name if you already know an external identifier."
5. **`/extend`** — fetch GND/GeoNames/Wikidata identifiers for an already-matched
   entity. Ties back to point 3: these are the same property definitions doing double
   duty as both match conditions *and* extendable output columns.
6. **OpenRefine live** (section C) — reconcile a small real column end-to-end, then
   pull in an extend column. This is the "yes, it interoperates with the actual
   ecosystem tool people use" moment.
7. **The official testbench** (section B1) running its full conformance suite green
   against our server, for both spec versions — "this isn't just self-reported, it's
   validated against the spec authors' own tooling."
8. **The annotation editor doing this inline** while editing a TEI document (§B3) — the
   most visually compelling one, now verified end-to-end (see §B3's 2026-07-24 update
   and `annotate-reconciliation.cy.js`): click a tagged person entity, hit edit, watch
   the search hit our own `/api/reconcile`, select the candidate it returns.

---

## Known gaps (things intentionally left for later)

- **OpenRefine batch reconciliation bugs (section C) — fixed 2026-07-24.** Malformed
  batch entries (null/scalar queries, non-numeric `limit`) used to either 500 the whole
  request or silently misalign results; both wire formats now degrade a bad entry to
  "zero candidates at its correct position" instead. Covered by 5 new Cypress tests.
  **Still worth a real OpenRefine re-run** to confirm the actual ecosystem client is
  happy, not just the curl-level repro.
- **Annotate-editor click-through** (B3 above) — **fully fixed and verified 2026-07-24,
  no open items left.** Verified from a truly fresh app creation (deleted `tp-reconc`
  completely, `jinks create`'d again, screenshotted): the `XQDY0025` core bug
  (tei-publisher-lib 6.1.1) applies automatically to any new app with no extra steps;
  the "missing `annotation-config.xqm` functions" issue was session-specific stale
  state, not a real bug — a fresh create already produces a working copy; layout is
  clean with the theme in the `-c` config from the start. The Reconciliation connector
  querying `metagrid.ch` was also root-caused and fixed: `createConnectors()` silently
  falls back to `Metagrid` for any unrecognized `connector` attribute value — the exact
  string must be `connector="ReconciliationService"`. All of it is now covered by
  `reconcile/test/cypress/e2e/gui/annotate-reconciliation.cy.js`, an automated
  regression test for the full click → search → select flow against our own endpoint.
- Extending a property via an arbitrary XPath (e.g. "all document URLs where this
  entity occurs") isn't supported by the current `properties` config shape — open
  design question, not started.
- Everything else from the earlier "gaps" list (CI, testbench re-run, production
  hardening) is done — see "Where things stand" at the top.
