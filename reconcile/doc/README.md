# Reconciliation Service API — customizing the entity model

This profile implements the [OpenRefine Reconciliation Service API](https://reconciliation-api.github.io/specs/)
(0.2 and 1.0-draft) as a generic HTTP layer on top of a **configurable type registry**. Everything
domain-specific — what counts as a "person"/"place"/"organization", how a label is extracted, which
properties are fetchable, how a preview renders, how candidates are ranked — lives in one file,
`modules/reconcile-config.xql`, not in the HTTP handlers (`modules/reconcile-api.xql`).

## What ships by default

`reconcile-config.xql` ships defaults for four types — `person`, `place`, `organization`, `work` —
read from the app's `registers` collection (`$config:register-root`/`$config:register-map` — a
**base10** convention, the same one the `annotate` entity editors write to). Matching/ranking uses
a string-similarity function with a typo-tolerant fallback tier, `reconc-score:default` in
`modules/reconcile-scoring.xql` (see "Matching / ranking" below); `person`/`place`/`work` also
pre-filter candidates through a Lucene full-text index for speed on larger collections (see
`"fulltext-search"` below) — `organization` doesn't, since it has no real data or index in this
demo app to validate one against. `person`/`place` additionally match against every name *variant*
an entity has, not just its primary display name (see `"labels"` below), and all four types expose
a few real external-identifier extend properties (GND for person/work, GeoNames/Wikidata for place)
alongside their original ones.

This profile only `depends` on `base10`. The **`registers` profile** (the one that adds the
`/people`, `/places`, ... browse pages) is entirely optional: if it's installed, `GET
/api/reconcile/entity/{id}` redirects to its browse page for types that configure a `"view"`; if
it isn't, the same endpoint transparently falls back to a built-in ODD-based preview instead — see
`"view"` below. There is no scenario where a shipped default requires `registers` to be present.

## Customizing it

Edit `modules/reconcile-config.xql` directly in your app checkout. It's an ordinary, `jinks
update`-tracked file: a fresh `jinks create` copies these defaults in, and if you edit the file
afterwards, a later `jinks update` will detect the change and report a **conflict** — the file is
left untouched, not silently overwritten. (Choosing to "resolve" that conflict via `jinks-cli`
means *accepting the profile's upstream defaults and discarding your edit* — there's no "keep mine
and stop nagging" option in Jinks today, so just leave the conflict unresolved and it'll keep being
reported, harmlessly, on every future update.)

### Adding/removing/redefining a type

Each entry in `$reconc-config:TYPES` is a map:

```xquery
"person": map {
    "name": "Person",                    (: display name, manifest + suggest/type :)
    "view": "people",                    (: optional: registers browse-page name for /entity/{id} — see below :)
    "entities": function() as element()* {
        collection($config:register-root)/id($config:register-map?person?id)//tei:person[@xml:id]
    },
    "label": function($e as element()) as xs:string { ... },   (: OR an xs:string XPath — see below :)
    "labels": function($e as element()) as xs:string* { ... }, (: optional: every name variant to match against — see below :)
    "fulltext-search": function($query as xs:string) as element()* { ... },  (: optional: Lucene pre-filter — see below :)
    "preview-mode": "register-overview", (: optional: ODD web-transform mode for the default preview :)
    "preview": function($e as element()) as node() { ... },    (: optional: full override of preview rendering :)
    "properties": map {
        "gender": map { "name": "Gender", "value": function($e as element()) as xs:string* { ... } }
    }
}
```

To point at completely different content — a different collection, a non-register vocabulary, a
different TEI element altogether — just write a different `"entities"` closure; nothing else in
the profile needs to know or care. To drop a type, remove its entry; to add one, add a new key.
Property ids only need to be unique *within* a type's `properties` map, not globally — the shipped
defaults actually rely on this (both `"person"` and `"work"` have a `"gnd"` property, each with its
own extractor); `/extend` always resolves a property against the *matched entity's own type*, never
just the first type that happens to define a property with that id.

`"entities"` is always a zero-argument function item (never a bare XPath string) — the context for
a *selection* XPath (which collection? relative to what?) is inherently ambiguous, so a closure is
both clearer and no more work to write.

### Function items vs. XPath strings for `"label"` and property `"value"`

Both are accepted, and mean the same thing: "given the matched entity node, produce the label /
property value(s)". A function item is called directly. An `xs:string` is treated as a **relative**
XPath expression and evaluated dynamically against the entity (e.g. `".//tei:persName[@type='main'][1]"`,
`"@type"`, or just `"."` to use the whole entity's text).

```xquery
"label": ".//tei:persName[@type='main'][1]"
```

is equivalent to

```xquery
"label": function($e as element()) as xs:string {
    normalize-space($e/tei:persName[@type = "main"][1])
}
```

**Tradeoffs, so you can choose deliberately:**

- **XPath strings** are quick to write for anyone who knows XPath but not XQuery function syntax,
  and read declaratively in the config file.
- **Function items** are what the shipped defaults use, and are the better choice whenever you need
  more than a single path expression: combining multiple fields, falling back through several
  candidates, calling another function, cross-referencing other data. They're also faster (compiled
  once, not re-evaluated as a string each call) and don't widen the trust boundary — see below.
- Dynamic evaluation (`util:eval`, which is what an XPath string ultimately goes through) runs with
  **the full permissions of the calling module** — it is not a sandboxed XPath-only evaluator, it's
  full XQuery 3.1 with access to anything importable from `reconcile-api.xql`'s own static context
  (though that module deliberately keeps its imports minimal). This is a non-issue if only a trusted
  app developer/administrator ever edits `reconcile-config.xql` (the normal case — it's a profile
  source file, not end-user input), but is worth knowing if you ever consider exposing this file to
  a less-trusted editor.

### `"view"`: redirecting to a browse page, safely

`"view"` controls what `GET /api/reconcile/entity/{id}` does for a type, and accepts either:

- an `xs:string` naming a `registers`-profile browse page (e.g. `"people"`) — but it's only
  actually used if the `registers` profile is confirmed installed in *this* app
  (`reconc-config:profile-installed("registers")`, checked against the generator's own
  `context.json` at request time, not assumed); otherwise the endpoint falls through to the same
  default preview rendering used when no `"view"` is set at all. This is what lets the shipped
  `"view": "people"`/`"places"` defaults work identically whether or not you happen to have
  `registers` installed — you never need to remove them yourself.
- a `function($id as xs:string, $found as map(*), $request as map(*)) as item()*` for full control
  — build the response yourself with `router:response(...)` (redirect somewhere else entirely,
  render something bespoke, whatever you need). `reconc-config:profile-installed(...)` is public,
  so a custom override can reuse the same "is this other profile actually here" check.
- omitted entirely — always uses the default preview rendering (same as the string case when
  `registers` isn't installed).

```xquery
"view": function($id as xs:string, $found as map(*), $request as map(*)) as item()* {
    router:response(303, (), (), map { "Location": "https://example.org/persons/" || $id })
}
```

### `"labels"`: matching every name variant, not just the display name

Real entities often have more than one name worth matching against — historical spellings,
abbreviations, sort forms — even though only one of them should ever be *shown*. `"labels"` is the
plural sibling of `"label"`: same rules (function item or XPath string, but expected to select more
than one node), used only for **scoring**, never for display. A query is scored against every
variant and the best match wins; `candidate.name` in the response always comes from `"label"`
alone, untouched.

```xquery
"labels": function($e as element()) as xs:string* {
    $e/tei:persName/string()   (: every persName, not just the "main" one "label" prefers :)
}
```

Omit it for a type that only ever has one name form — matching then just uses `"label"` by itself,
identical to before `"labels"` existed. That's why the shipped `"organization"`/`"work"` defaults
don't set it: this demo app's data for those two never has more than one name/title to begin with,
so there'd be nothing to gain.

### `"fulltext-search"`: fast candidate pre-filtering with fuzzy recall

For a type with more than a handful of entities, scoring every single one on every query gets slow.
`"fulltext-search"` is an optional, faster alternative to `"entities"` for the *matching* path (only
— `"entities"` itself is still used everywhere else, e.g. `/suggest/type`'s candidate counts):
`function($query as xs:string) as element()*`, expected to pre-filter down to plausible candidates
using a Lucene full-text index already declared in the app's `collection.xconf`.

```xquery
"fulltext-search": function($query as xs:string) as element()* {
    collection($config:register-root)/id($config:register-map?person?id)//tei:person[
        @xml:id and ft:query(., reconc-fulltext:fuzzy-query("name", $query), map { "leading-wildcard": "yes", "filter-rewrite": "yes" })
    ]
}
```

`reconc-fulltext:fuzzy-query($field, $query)` (from the small shared `modules/reconcile-fulltext.xql`,
already imported by this file) builds a Lucene query string with the classic `~` fuzzy operator on
every query token, so a typo still matches. **The `ft:query(...)` predicate has to be written
directly inside your own path expression, exactly like the example above** — it cannot be applied
afterwards as a filter on `("entities")()`'s result. eXist only rewrites `ft:query()` into an actual
index lookup when it's a predicate *inside* the same path expression doing the collection traversal;
applied to an already-materialized node sequence it still runs, just roughly 300x slower in testing
against this project's own demo data (955ms vs. 3ms for the same 33-entity collection) — the whole
point of this field is defeated if it's not written this way. Leaving `"fulltext-search"` unset (the
safe default) falls back to scoring every entity from `"entities"` individually — slower for a large
collection, but always correct regardless of what is or isn't indexed, so this is purely opt-in.
Only set it for a type whose element is genuinely covered by `collection.xconf` — the shipped
`person`/`place`/`work` defaults all reuse the same `"name"` field the `registers` profile itself
already searches; `"organization"` deliberately leaves it unset, since its `tei:org` elements aren't
indexed at all in the shipped `collection.xconf`.

### Matching / ranking

```xquery
declare variable $reconc-config:SCORE := reconc-score:default#2;
```

Point this at any `function($label as xs:string?, $query as xs:string?) as xs:double` — an external
NER/embedding-based similarity service, weighting by which properties also matched, whatever you
need. `reconc-score:default` in `modules/reconcile-scoring.xql` is public and composable, so you can
also wrap it (e.g. "call the default, then add a language-match boost") rather than writing one from
scratch. It already includes a typo-tolerant fallback tier: exact match scores 100, substring
containment and token overlap score proportionally, and — only once those all fail, and only for
tokens at least 4 characters with an edit distance of at most 2 — a hand-rolled Levenshtein-based
similarity kicks in, compared **token by token** rather than as whole strings (a typo in one word of
a multi-word name like "Goethe, Johann Wolfgang von" would rarely be within edit distance 2 of the
*whole* string, but easily is of just the one mistyped word). This fuzzy tier is what makes
`"fulltext-search"`'s Lucene-level fuzzy recall actually useful: without it, a fuzzy-matched
candidate would still score 0 and get silently dropped by `reconc:candidates`.

### Preview rendering

By default, `/preview` and the `/entity/{id}` fallback (used when a type has no `"view"` page) run
the entity through the app's own ODD transformation pipeline — the same `pm-config:web-transform`
call the `registers` profile itself uses — in the type's `"preview-mode"` (default
`"register-overview"`). Set a different `"preview-mode"` string to reuse another existing ODD mode,
or a `"preview"` function item (`function($entity as element()) as node()`) to fully replace
rendering for that type. No other endpoint needs extra configuration for a custom type: manifest,
`/suggest/*`, and `/extend`/`/extend/propose` all derive automatically from `$reconc-config:TYPES`.

### Batch requests and repeated work

A single `POST /api/reconcile` request can carry many queries at once. For any type *without*
`"fulltext-search"` (where the only way to find candidates is scoring every entity), `reconc:
reconcile-1.0`/`reconc:reconcile-0.2` precompute that type's entities/labels once per *request*
rather than once per *query* — invisible from the config side, nothing to opt into, but worth
knowing if you're reading `reconcile-api.xql`'s `reconc:candidate-pool`/`reconc:candidates`. Types
*with* `"fulltext-search"` don't need this: `ft:query()` is already a cheap, indexed, per-query-text
lookup, so there's nothing to usefully precompute ahead of knowing each query's text.

## Example: adding a fifth type

```xquery
"term": map {
    "name": "Keyword",
    "entities": function() as element()* {
        collection($config:register-root)/id($config:register-map?term?id)//tei:item[@xml:id]
    },
    "label": ".",
    "properties": map {}
}
```

(No `"view"` — falls back to the default ODD-based preview. No `"preview-mode"` — defaults to
`"register-overview"`. Property-free — still perfectly valid for reconciliation queries.)

## Testing

- `test/cypress/e2e/api/reconcile.cy.js` — the project's main integration suite (schema-validated
  against both spec versions), exercises the shipped defaults end-to-end over HTTP.
- `test/xqsuite/reconcile-config.xqm` — layer-1 unit tests, decoupled from HTTP: check the shipped
  defaults resolve against real register data, and separately prove the *mechanism* a custom config
  relies on (XPath-string extraction via `util:eval`, a swapped scoring function,
  `reconc-config:profile-installed` against both a real-and-present and a made-up-and-absent
  profile name, the fuzzy scoring tier on both a whole-word and a one-word-of-many typo, the
  `"labels"` extractor covering more than just the primary `"label"`, `reconc-config:gnd-uri-from-id`,
  and the new external-identifier properties resolving against real data) works, using stand-ins
  deliberately different from the shipped defaults where relevant.
- The Cypress suite also covers a misspelled single-token query still finding its match with a
  nonzero score, a batched query returning identical candidates to the same query sent alone (the
  batch-pool refactor doesn't change results), and the new `gnd`/`geonames`/`wikidata`/`occupation`
  extend properties resolving against real entities — including the `"gnd"` property defined on both
  `"person"` and `"work"` resolving against whichever type the requested entity actually is.
