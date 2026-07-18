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

If the container isn't running: `skills/teipublisher-reconciliation-testing/scripts/up.sh`
(waits for readiness). If `tp-reconc` doesn't exist yet or seems out of date:
`jinks update tp-reconc -s http://localhost:8080/exist/apps/jinks -u tei -p simple`
(needs Node ≥22 — `export NVM_DIR="$HOME/.nvm"; source "$NVM_DIR/nvm.sh"; nvm use 22`).

---

## Where things stand right now

*(Written 2026-07-18, end of the production-hardening pass — update this section as
work continues so a future session/you-after-a-break can reorient in 30 seconds.)*

- All four planned follow-ups are **done and pushed**: (1) CI for this repo, (2) local
  testbench re-run after the matching rewrite, (3) *(deferred, see "Known gaps"
  below)*, (4) production-hardening (request-size caps + docs). Actually: item 3
  (annotate-editor click-through in a real browser) was **never completed** — see
  "Known gaps" at the end of this file, it's the main loose thread.
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
  an empty body.)
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

**Status: wired up and unit-verified (see the `annotate-reconciliation-client`
project memory), but never click-tested end-to-end in a real browser this session —
this is the one open item, verify it before relying on it live.** The demo app
(`tp-reconc`) does include the `annotate` profile, and `annotate-tei.html`/
`annotate-jats.html` are already configured with
`endpoint="/exist/apps/tp-reconc/api/reconcile"` for their Reconciliation Service /
Custom connector.

What's known: there's no simple standalone URL for the annotation editor (it 404s if
you try `annotate.html?doc=...` directly) — the real path in is a **mode toggle from
the normal document viewer** (a toolbar button, likely `pb-view-annotate.js`), not a
bookmarkable link. If you're prepping this for a presentation:

1. Open the app root (`http://localhost:8080/exist/apps/tp-reconc/`), browse to any
   document with tagged entities (person/place/org names), open it in the viewer.
2. Look for an "annotate" / edit-mode toggle in the toolbar.
3. Select or click an already-tagged name — an entity editor panel should appear
   with a "reconcile" / lookup action offering candidates from our server.

If step 2/3 don't match what you find, that's expected — this wasn't finished. Falling
back to the standalone testbench (B1) or curl (A) is the safe choice for a live demo
you haven't rehearsed.

---

## C. OpenRefine

1. Install/open OpenRefine, create or open any project with a text column of names
   (e.g. a column containing "Goethe", "Dantiscus", "Madrid", ...).
2. Click the column's dropdown ▾ → **Reconcile → Start reconciling...**
3. In the dialog, click **Add Standard Service...** and paste:
   ```
   http://localhost:8080/exist/apps/tp-reconc/api/reconcile
   ```
   (Recent OpenRefine versions auto-detect 1.0-draft from the manifest. If your
   OpenRefine is older / only speaks 0.2, append `?version=0.2` to the URL instead.)
4. Pick a type (Person/Place/Organization/Work) if prompted, click **Start Reconciling**.
   OpenRefine batches the column's values into exactly the batch protocol tested in
   section A — you should see scored candidates appear per cell, with the best match
   pre-selected above the match-confidence threshold.
5. To try data extension: after reconciling, use **Edit column → Add columns from
   reconciled values...** and pick one of the extend properties (gnd/gender/occupation
   for person, geonames/wikidata for place) — this exercises `/extend` exactly like
   the curl examples in section A.

This is a good "does it actually work with the real ecosystem tool" check, distinct
from both our own Cypress suite and the spec's own testbench.

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
8. *(If you got B3 working ahead of time)* the annotation editor doing this inline
   while editing a TEI document — the most visually compelling one, but only show it
   if you've rehearsed it, since it's the one path not yet verified end-to-end.

---

## Known gaps (things intentionally left for later)

- **Annotate-editor click-through** (B3 above) — never verified in a real browser
  this session. If you get to it, update this file and the
  `local-env-node-podman`/`annotate-reconciliation-client` memories with what you find
  (especially the actual toolbar/mode-toggle path into the editor).
- Everything else from the earlier "gaps" list (CI, testbench re-run, production
  hardening) is done — see "Where things stand" at the top.
