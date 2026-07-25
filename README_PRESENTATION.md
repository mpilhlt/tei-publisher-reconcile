# Presentation script — Reconciliation in TEI Publisher

A ~20-minute talk for a **TEI/digital-editions audience** (not necessarily software
engineers): what reconciliation is, why OpenRefine made it the DH community's de facto
entity-linking protocol, and how TEI Publisher now speaks it in both directions. For
functional test routines instead of a talk script, see
**[`README_MANUAL_TESTING.md`](README_MANUAL_TESTING.md)**.

**Format**: intro (why this matters to *this* audience specifically) → two live demos
(server side, then client side) → the extensibility/conformance story → wrap-up. Each
demo section has a rehearsed script, what to say while it loads, and a fallback if
something breaks live.

---

## Before you go on stage

- [ ] `podman ps` — container up; `curl -s $BASE | jq .type` responds (see §0 below for
      `$BASE`).
- [ ] `tp-reconc` generated with the full demo config (`annotate`/`upload`/`jinntap`/
      `theme-base10` + `reconcile`), **freshly reset** so the demo entities are in their
      pristine, un-annotated state — you want to *perform* the linking live, not show
      already-linked data. (`README_TEST_CONTAINER.md` covers a clean reset.)
- [ ] OpenRefine open, with a small project already loaded (a text column of ~5-10
      names — mix a couple of instantly-recognizable ones like "Goethe" with a couple of
      your own demo data's names, e.g. "Thurneysen", "Dantiscus"). Reconciling *live*
      from a blank project burns minutes you don't have; loading data is fine to do
      ahead of time, reconciling against the service is the part to actually demo.
- [ ] Browser tabs pre-opened, in this order, so alt-tab matches your talk order:
      1. This app's manifest (`$BASE`)
      2. OpenRefine
      3. A TEI document open in the annotate editor, on an **untagged** or
         freshly-reset entity
      4. The official testbench, already pointed at your endpoint
- [ ] Screen font size large enough to read from the back row — OpenRefine's reconcile
      dialog and the annotate editor's popup text are both small by default.
- [ ] A recorded screen-capture (GIF or short video) of each live-demo section as backup,
      linked from your slides, in case the network/container misbehaves mid-talk. Live
      demos of a running server are inherently the riskiest part of any talk — rehearse
      the fallback switch, not just the happy path.

```bash
BASE=http://localhost:8080/exist/apps/tp-reconc/api/reconcile
```

---

## 0. Cold open — the problem (≈2 min)

**Talking point**: every digital edition ends up with the same problem — the same
person, place, or work needs to be *the same identifiable thing* across documents,
across editions, and ideally across projects entirely. Hand-typed `@ref` values drift.
Two editors spell a name two different ways. A new team member has no idea which of
three "Johann Wolfgang von Goethe" entries in the register is canonical. Authority
control is not a new problem — but it's usually solved with a bespoke, project-specific
tool that nobody outside that project can use.

**Bridge**: the data-science/DH-adjacent world already solved a version of this with
**OpenRefine**, the open-source data-cleaning tool many of you have probably used to tidy
up a spreadsheet before turning it into TEI. OpenRefine has a built-in feature called
*reconciliation*: point a column of text at an authority service, and it comes back with
candidate matches, scored, ready to accept. What's less widely known: that feature runs
on an open, documented HTTP protocol — the **Reconciliation Service API** — that isn't
tied to OpenRefine at all. Wikidata, the German GND (via lobid.org), Getty's
vocabularies, and dozens of other authorities all speak it.

*(Suggested screenshot/slide: OpenRefine's "Start reconciling" dialog against a public
service like Wikidata — establishes the concept before you show your own server.)*

**The pitch for this talk**: TEI Publisher now speaks this same protocol in **both
directions**. Your own TEI Publisher application can *become* a conforming
reconciliation service — so OpenRefine, or any other conforming tool, can reconcile
against *your* registers. And, going the other way, the annotation editor you already
use to tag entities can reconcile *against* any conforming service — including your own
— live, while you edit.

---

## 1. Live demo — your app as a reconciliation service (≈7 min)

**Setup already done**: OpenRefine open with a name column loaded.

**Script**:

1. Briefly show the manifest in a browser tab (`$BASE`) — "this is what makes it a
   *service*: a small, standard JSON description of what it can do. Any conforming
   client can read this and know how to talk to us." Point at `versions` (both the
   mature 0.2 protocol and the newer 1.0-draft — you support the whole community's
   install base, not just the newest spec) and `suggest`/`extend` (type-ahead and
   data-extension support — not just bare matching).

   *(Screenshot suggestion: the manifest JSON, pretty-printed — see
   `reconcile-manifest.png` in the docs site for a ready-made one, or take your own.)*

2. Switch to OpenRefine. Column ▾ → **Reconcile → Start reconciling...** → **Add
   Standard Service...** → paste the endpoint URL. Pick a type (Person). **Start
   Reconciling**.

3. While it runs: "Under the hood this batches every row into one request, scores each
   candidate with typo-tolerant string matching — so a misspelled name still finds its
   match — and answers with exactly the shape OpenRefine expects, because we validated
   this against the reconciliation-api project's own official conformance suite, not
   just our own guesses about the spec."

4. Results land: point out scores, and click into one match's judgment call — a name
   with two plausible candidates. "This is where it gets useful for real editorial
   work": show reconciling with a **second column as a property condition** (e.g. also
   matching on a known role/gender/date) to disambiguate two same-named people —
   "exactly the same feature you'd use to tell apart two Johann Müllers."

5. **Data extension** — pull data *back* into the spreadsheet: Edit column → **Add
   columns from reconciled values...** → pick an extend property (GND id, for instance).
   "Now my messy spreadsheet has authority-controlled identifiers I can paste straight
   into `@ref`, without leaving OpenRefine."

   *(Note: for this specific feature, the service needs to be added with `?version=0.2`
   on the URL — OpenRefine's own client only understands the older manifest shape for
   data extension specifically, not a limitation of the newer protocol version or of
   this server. Worth a one-line mention if someone asks, not worth derailing the demo
   over.)*

**If the live reconcile call fails or hangs**: switch immediately to the official
testbench tab (§3 below) or a pre-recorded clip — don't debug live. "Let me show you the
same thing against the spec's own reference client instead" is a graceful recovery, not
an admission of failure.

---

## 2. Live demo — reconciling *while you edit* (≈7 min)

**Setup already done**: a TEI document open in the annotate editor, on a fresh/untagged
entity mention.

**Script**:

1. "So far that's the classic OpenRefine workflow — batch-clean a spreadsheet, then
   import into your edition. But most entity tagging doesn't happen in a spreadsheet, it
   happens while you're transcribing and marking up the document itself." Point at an
   already-tagged entity elsewhere in the document, click it: the popup shows a real,
   live preview — biography, dates, whatever the connector's own preview renders — "not
   a bare id, an actual answer to 'who is this.'"

   *(Screenshot suggestion: the click-to-view detail popup — `reconcile-annotate-detail.png`
   in the docs site.)*

2. Select an untagged name, tag it as a person, click the pencil/edit icon. A search
   panel opens. Type a query.

3. "Watch the results list" — candidates appear from **more than one source in one
   list**: your own local register (if this person is already known to your edition)
   *and* an external authority like GND, side by side, badged by where they came from.
   "This is the same reconciliation protocol from the OpenRefine demo, just now running
   as you type, and it can federate more than one authority at once."

   *(Screenshot suggestion: the federated search results with source badges —
   `reconcile-annotate-search.png` in the docs site.)*

4. Select a match. Show the resulting TEI markup (switch to source view, or point at the
   inline `@ref`/`@key` attributes right in the rendered text): "One click, and the
   entity is linked, with a real external identifier attached — and if I click it again
   right now, I get that same rich preview from a moment ago."

5. **The tie-back to demo 1, explicitly stated**: "This isn't a separate feature bolted
   on — it's the exact same server-side protocol. If your edition project runs its own
   reconciliation service the way I showed a moment ago, this editor is already a client
   for it. You get OpenRefine-style batch cleanup *and* inline, live linking, from one
   implementation."

**If the search panel doesn't return results**: check you're on a genuinely fresh/reset
document (a previous rehearsal may have already linked this exact entity — search still
"works" but looks unimpressive against an already-answered query). Fallback:
pre-recorded clip, or switch to a second prepared document.

---

## 3. Under the hood, briefly (≈2 min)

Pick **one or two** of these, depending on the room (a more technical audience: lead with
the pluggable model; a more editorially-focused audience: lead with conformance/trust):

- **Pluggable, not hardcoded.** What counts as a "person," how a label is extracted,
  which properties are fetchable, how a preview renders — all defined in one plain,
  editable file. Adding a fifth entity type, or pointing an existing one at completely
  different data, needs no code changes elsewhere. "This isn't a fixed schema we
  imposed — it adapts to how your project already models people, places, and works."
- **Spec-conformant, provably.** Both protocol versions validate green against the
  reconciliation-api project's own official testbench — the same tool the spec authors
  use to certify any service. *(Live if time allows / screenshot otherwise: the
  testbench's checkmarks for Manifest/Reconcile/Suggest/Preview/Extend.)*
- **Decoupled.** The server doesn't need the editor; the editor doesn't need this
  server. Point the editor at Wikidata's reconciliation service, or GND directly, or
  three services federated together, with no code changes — and point any other
  conforming tool (not just this editor, not just OpenRefine) at your server.

---

## 4. Wrap-up (≈1-2 min)

- One sentence each: "reconcile against anything, be reconciled against by anything, and
  both from inside the tool you already use to build your edition."
- Where to read more: this project's docs site (`/doc/reconcile.xml`,
  `/doc/annotations.xml` — link them on a closing slide), the reconciliation-api spec
  itself (`reconciliation-api.github.io/specs`) for anyone who wants to build their own
  client or service.
- Invite questions — the disambiguation-via-property-condition feature (demo 1, step 4)
  and the federated-search badges (demo 2, step 3) tend to be the two things people ask
  follow-ups about; have those two flows fresh in mind.

---

## Timing cheat sheet

| Section | Target | Cumulative |
|---|---|---|
| 0. Cold open | 2 min | 2 min |
| 1. Server demo (OpenRefine) | 7 min | 9 min |
| 2. Client demo (annotate editor) | 7 min | 16 min |
| 3. Under the hood | 2 min | 18 min |
| 4. Wrap-up | 1-2 min | 20 min |

If running long, cut from §3 first (it's the least visual section), then trim demo steps
to their single most impressive moment (data extension in §1, the federated-badge search
in §2) rather than showing every step.
