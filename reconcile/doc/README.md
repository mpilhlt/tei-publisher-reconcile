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
a simple string-similarity function, `reconc-score:default` in `modules/reconcile-scoring.xql`.

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
Property ids only need to be unique *within* a type's `properties` map, not globally.

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

### Matching / ranking

```xquery
declare variable $reconc-config:SCORE := reconc-score:default#2;
```

Point this at any `function($label as xs:string?, $query as xs:string?) as xs:double` — fuzzy
matching, an external NER/embedding-based similarity service, weighting by which properties also
matched, whatever you need. `reconc-score:default` in `modules/reconcile-scoring.xql` is public and
composable, so you can also wrap it (e.g. "call the default, then add a language-match boost")
rather than writing one from scratch.

### Preview rendering

By default, `/preview` and the `/entity/{id}` fallback (used when a type has no `"view"` page) run
the entity through the app's own ODD transformation pipeline — the same `pm-config:web-transform`
call the `registers` profile itself uses — in the type's `"preview-mode"` (default
`"register-overview"`). Set a different `"preview-mode"` string to reuse another existing ODD mode,
or a `"preview"` function item (`function($entity as element()) as node()`) to fully replace
rendering for that type. No other endpoint needs extra configuration for a custom type: manifest,
`/suggest/*`, and `/extend`/`/extend/propose` all derive automatically from `$reconc-config:TYPES`.

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
  profile name) works, using stand-ins deliberately different from the shipped defaults.
