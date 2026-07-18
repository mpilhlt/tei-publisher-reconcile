xquery version "3.1";

module namespace reconc="http://teipublisher.com/api/reconcile";

import module namespace config="http://www.tei-c.org/tei-simple/config" at "config.xqm";
import module namespace pm-config="http://www.tei-c.org/tei-simple/pm-config" at "pm-config.xql";
import module namespace reconc-config="http://teipublisher.com/api/reconcile/config" at "reconcile-config.xql";
import module namespace router="http://e-editiones.org/roaster";
import module namespace errors="http://e-editiones.org/roaster/errors";

declare namespace tei="http://www.tei-c.org/ns/1.0";

(:~ All entity types this service can be reconciled against are defined in
 : reconcile-config.xql ($reconc-config:TYPES) — see that file for how to add, remove or
 : redefine a type, or swap the matching/ranking algorithm ($reconc-config:SCORE). This
 : module only implements the HTTP-facing reconciliation protocol on top of it. :)

(:~ Resolves a "label"/property "value" config entry to a callable extractor.
 : Config values may be a function item (called as-is), or an xs:string containing
 : a *relative* XPath expression (e.g. ".", ".//tei:persName[1]", "@type") evaluated
 : against the entity via util:eval — the entity is bound as $data and the string
 : is appended as a path step ("($data)/" || $xpath), so util:eval's dynamic context
 : inherits this module's `tei` namespace declaration and the $data binding. A
 : parenthesized "($data)/" prefix (rather than bare "$data" concatenation) avoids
 : the XPath expression's first token being lexed as part of the variable reference
 : itself (e.g. "$data" || "." would otherwise parse as the single token "$data.").
 : See reconcile/doc/README.md for the tradeoffs. :)
declare %private function reconc:resolve-extractor($value) as function(*) {
    if ($value instance of function(*)) then
        $value
    else
        function($data as item()*) as item()* {
            util:eval("($data)/" || $value)
        }
};

(:~ All registered entities for a reconciliation type id, e.g. "person". :)
declare %private function reconc:entities($type-id as xs:string) as element()* {
    let $type-def := $reconc-config:TYPES?($type-id)
    return
        if (exists($type-def)) then
            ($type-def?entities)()
        else
            ()
};

(:~ Finds a single entity by id across all reconciliation types. Returns a map
 : {entity, type-id}, or the empty sequence if no type's register contains it. :)
declare %private function reconc:entity-by-id($id as xs:string) as map(*)? {
    let $match :=
        for $type-id in map:keys($reconc-config:TYPES)
        let $entity := reconc:entities($type-id)[@xml:id = $id]
        where exists($entity)
        return map { "entity": $entity, "type-id": $type-id }
    return head($match)
};

(:~ Human-readable label for a matched entity, per its type's configured "label" extractor. :)
declare %private function reconc:label($entity as element(), $type-id as xs:string) as xs:string {
    let $extractor := reconc:resolve-extractor($reconc-config:TYPES?($type-id)?label)
    let $raw := $extractor($entity)
    return normalize-space(string-join(for $r in $raw return string($r), " "))
};

(:~ Every name-variant string worth matching a query against for an entity, per its
 : type's optional "labels" (plural) extractor. Falls back to a single-element
 : sequence containing just reconc:label(...) when no "labels" extractor is
 : configured (or it produces nothing usable) — so scoring for types that don't set
 : it (this profile's own "organization"/"work" defaults, or any custom type) is
 : identical to before "labels" existed. :)
declare %private function reconc:labels($entity as element(), $type-id as xs:string) as xs:string* {
    let $labels-def := $reconc-config:TYPES?($type-id)?labels
    let $variants :=
        if (exists($labels-def)) then
            let $extractor := reconc:resolve-extractor($labels-def)
            for $r in $extractor($entity)
            let $s := normalize-space(string($r))
            where $s != ""
            return $s
        else
            ()
    return
        if (exists($variants)) then
            $variants
        else
            (reconc:label($entity, $type-id))
};

declare %private function reconc:normalize-text($s as xs:string?) as xs:string {
    lower-case(normalize-space($s))
};

(:~ Reads a reconciliation "type" value, which may be absent, a single string, or an array of strings. :)
declare %private function reconc:normalize-types($type) as xs:string* {
    if (empty($type)) then
        ()
    else if ($type instance of array(*)) then
        $type?*
    else
        $type
};

(:~ Pre-filters a type's entities via its configured "fulltext-search" closure
 : (see reconcile-config.xql's doc for that field) so only plausible candidates
 : reach the (much more expensive, per-candidate) scoring in reconc:candidates. An
 : empty/blank query can't be turned into a useful Lucene query, so it falls back
 : to every entity of the type — harmless, since an empty query scores 0 against
 : everything anyway and gets filtered out downstream. :)
declare %private function reconc:fulltext-prefilter($type-def as map(*), $query as xs:string?) as element()* {
    if (normalize-space($query) eq "") then
        ($type-def?entities)()
    else
        ($type-def?fulltext-search)($query)
};

(:~ {id, label, labels} for a single matched entity — the per-entity data
 : reconc:candidates actually scores against, however the entity was found
 : (full scan, Lucene pre-filter, or a precomputed batch pool). :)
declare %private function reconc:candidate-entry($entity as element(), $type-id as xs:string) as map(*) {
    map {
        "id": $entity/@xml:id/string(),
        "label": reconc:label($entity, $type-id),
        "labels": reconc:labels($entity, $type-id)
    }
};

(:~ {id, label, labels} for every entity of a type — the expensive part of
 : full-scan matching (reading the whole collection, extracting every name
 : variant) computed once so a batch request can reuse it across queries instead
 : of redoing it per query (see reconc:candidate-pool). Also used directly by
 : reconc:candidates for a single, unpooled query against a type with no
 : "fulltext-search" (where there's no cheaper way to narrow the candidate set). :)
declare %private function reconc:label-pool-for-type($type-id as xs:string) as map(*)* {
    for $e in reconc:entities($type-id)
    return reconc:candidate-entry($e, $type-id)
};

(:~ Builds a batch-wide pool (type id -> reconc:label-pool-for-type's result) for
 : every given type that does *not* have a "fulltext-search" configured — those
 : types have no cheaper way to narrow candidates than a full scan, so it's worth
 : precomputing once per request rather than once per query in the batch. Types
 : *with* a "fulltext-search" are deliberately left out: reconc:fulltext-prefilter
 : is a cheap, indexed, per-query-text lookup, so there's nothing to usefully
 : precompute for them ahead of knowing each query's text. Called once per batch
 : request (reconc:reconcile-1.0/0.2), not once per query. :)
declare %private function reconc:candidate-pool($type-ids as xs:string*) as map(*) {
    map:merge(
        for $type-id in $type-ids
        let $type-def := $reconc-config:TYPES?($type-id)
        where exists($type-def) and empty($type-def?fulltext-search)
        return map:entry($type-id, reconc:label-pool-for-type($type-id))
    )
};

(:~ Find and score candidates for a query string, restricted to the given type ids
 : (all default types if empty). $pool optionally supplies precomputed candidate
 : entries for one or more types (see reconc:candidate-pool) — a type missing from
 : $pool (including every type, when $pool is the default map {}) is always
 : resolved fresh here, via its "fulltext-search" pre-filter if it has one, or a
 : full scan otherwise. This is what makes $pool purely a batch-request
 : optimization, never a correctness requirement: single-query callers (e.g.
 : reconc:suggest-entity) simply don't pass one. :)
declare %private function reconc:candidates($type-ids as xs:string*, $query as xs:string?, $limit as xs:integer, $pool as map(*)) as map(*)* {
    let $types := if (empty($type-ids)) then map:keys($reconc-config:TYPES) else $type-ids
    let $scored :=
        for $type-id in $types
        let $type-def := $reconc-config:TYPES?($type-id)
        where exists($type-def)
        let $entries :=
            if (map:contains($pool, $type-id)) then
                $pool($type-id)
            else if (exists($type-def?fulltext-search)) then
                for $e in reconc:fulltext-prefilter($type-def, $query)
                return reconc:candidate-entry($e, $type-id)
            else
                reconc:label-pool-for-type($type-id)
        for $entry in $entries
        let $score := max(for $l in $entry?labels return ($reconc-config:SCORE)($l, $query))
        where $score > 0
        return
            map {
                "id": $entry?id,
                "name": $entry?label,
                "type-id": $type-id,
                "score": $score
            }
    let $sorted := sort($scored, (), function($c) { -$c?score })
    return
        subsequence($sorted, 1, max(($limit, 0)))
};

declare %private function reconc:format-candidate($candidate as map(*)) as map(*) {
    map {
        "id": $candidate?id,
        "name": $candidate?name,
        "score": $candidate?score,
        "match": $candidate?score >= 95,
        "type": [
            map {
                "id": $candidate?type-id,
                "name": $reconc-config:TYPES?($candidate?type-id)?name
            }
        ]
    }
};

declare %private function reconc:site-root($request as map(*)) as xs:string {
    let $scheme := request:get-scheme()
    let $host := request:get-server-name()
    let $port := request:get-server-port()
    let $default-port := if ($scheme = "https") then 443 else 80
    let $authority := if ($port = $default-port) then $host else $host || ":" || $port
    let $app-link := substring-after($config:app-root, repo:get-root())
    let $path := string-join((request:get-context-path(), request:get-attribute("$exist:prefix"), $app-link), "/")
    return
        $scheme || "://" || $authority || replace($path, "/+", "/")
};

declare %private function reconc:base-url($request as map(*)) as xs:string {
    reconc:site-root($request) || "/api/reconcile"
};

(:~
 : Reconciliation Service Manifest.
 : GET /api/reconcile [?version=0.2|1.0-draft]
 :
 : A single manifest cannot simultaneously satisfy both the 0.2 and 1.0-draft JSON
 : Schemas: 0.2 requires identifierSpace/schemaSpace while 1.0-draft requires a
 : "view" object, and the "suggest" sub-object has incompatible shapes (booleans
 : vs. service-definition objects) between the two. The default (no ?version)
 : manifest is 1.0-draft-only; pass ?version=0.2 to get a 0.2-only manifest. The
 : local reconciliation-api testbench determines the protocol version purely by
 : checking which schema the fetched manifest validates against, so point it at
 : the plain endpoint for a 1.0-draft run and at "?version=0.2" for a 0.2 run.
 :)
declare function reconc:manifest($request as map(*)) {
    let $extend-param := $request?parameters?extend
    return
        if (exists($extend-param) and normalize-space($extend-param) != "") then
            (: Classic (pre-1.0) data-extension convention: GET the service root with an
             : "extend" query parameter, still used by the local reconciliation test bench's
             : data-extension tab. See reconc:extend. :)
            reconc:extend-response(parse-json($extend-param), $request?parameters?version)
        else
            reconc:manifest-response($request)
};

declare %private function reconc:manifest-response($request as map(*)) {
    let $version := $request?parameters?version
    let $base := reconc:base-url($request)
    let $default-types := array {
        map:for-each($reconc-config:TYPES, function($id, $def) { map { "id": $id, "name": $def?name } })
    }
    return
        if ($version = "0.2") then
            map {
                "versions": ["0.2"],
                "name": "TEI Publisher Reconciliation Service",
                "identifierSpace": "https://teipublisher.com/register/id/",
                "schemaSpace": "https://teipublisher.com/register/schema/",
                "defaultTypes": $default-types,
                "view": map {
                    "url": $base || "/entity/{{id}}"
                },
                "preview": map {
                    "url": $base || "/preview?id={{id}}",
                    "width": 400,
                    "height": 300
                },
                "suggest": map {
                    "entity": map { "service_url": $base, "service_path": "/suggest/entity" },
                    "type": map { "service_url": $base, "service_path": "/suggest/type" },
                    "property": map { "service_url": $base, "service_path": "/suggest/property" }
                },
                "extend": map {
                    "propose_properties": map { "service_url": $base, "service_path": "/extend/propose" }
                }
            }
        else
            map {
                "versions": ["1.0-draft"],
                "name": "TEI Publisher Reconciliation Service",
                "view": map {
                    "url": $base || "/entity/{{id}}"
                },
                "defaultTypes": $default-types,
                "preview": map {
                    "url": $base || "/preview?id={{id}}",
                    "width": 400,
                    "height": 300
                },
                "suggest": map {
                    "entity": true(),
                    "property": true(),
                    "type": true()
                },
                "extend": map {
                    "proposeProperties": true()
                },
                "standardizedScore": true()
            }
};

(:~ Extracts the query text from a 1.0-draft query's conditions (the "name" match condition). :)
declare %private function reconc:query-text-from-conditions($query as map(*)) as xs:string? {
    let $condition := $query?conditions?*[?matchType = "name"][1]
    let $value := $condition?propertyValue
    return
        if ($value instance of map(*)) then
            ($value?name, $value?id)[1]
        else
            $value
};

(:~ All type ids a batch of queries could touch — each query's own "type"
 : restriction if given, or every default type for a query that doesn't restrict
 : type at all (matching reconc:candidates' own "empty means all types" rule) —
 : used to build the batch-wide candidate pool once up front (see
 : reconc:candidate-pool) rather than per query. Each query's own type list is
 : passed wrapped in an array; a plain "for $types in ...return $types" here would
 : flatten every query's types into one undifferentiated sequence, since a FLWOR
 : return of a sequence-valued expression flattens — the array keeps them apart
 : until unboxed with "?*" below (this is only needed for gathering the pool's type
 : set, not for reconc:candidates itself, which already accepts a plain sequence). :)
declare %private function reconc:all-queried-types($type-restrictions as array(*)*) as xs:string* {
    distinct-values(
        for $types in $type-restrictions
        let $ids := $types?*
        return if (empty($ids)) then map:keys($reconc-config:TYPES) else $ids
    )
};

declare %private function reconc:reconcile-1.0($body as map(*)) as map(*) {
    let $queries := $body?queries?*
    let $per-query-types := for $query in $queries return array { reconc:normalize-types($query?type) }
    let $pool := reconc:candidate-pool(reconc:all-queried-types($per-query-types))
    return
        map {
            "results": array {
                for $query at $i in $queries
                let $text := reconc:query-text-from-conditions($query)
                let $limit := ($query?limit, 10)[1]
                let $candidates := reconc:candidates($per-query-types[$i]?*, $text, $limit, $pool)
                return
                    map {
                        "candidates": array { for $c in $candidates return reconc:format-candidate($c) }
                    }
            }
        }
};

declare %private function reconc:reconcile-0.2($query-map as map(*)) as map(*) {
    let $keys := map:keys($query-map)
    let $per-query-types := for $key in $keys return array { reconc:normalize-types($query-map($key)?type) }
    let $pool := reconc:candidate-pool(reconc:all-queried-types($per-query-types))
    return
        map:merge(
            for $key at $i in $keys
            let $query := $query-map($key)
            let $text := $query?query
            let $limit := ($query?limit, 10)[1]
            let $candidates := reconc:candidates($per-query-types[$i]?*, $text, $limit, $pool)
            return
                map:entry($key, map {
                    "result": array { for $c in $candidates return reconc:format-candidate($c) }
                })
        )
};

(:~
 : Reconciliation query batch.
 : POST /api/reconcile and POST /api/reconcile/match (alias expected by the
 : 1.0-draft test bench, which always posts to "<endpoint>/match").
 :
 : The request shape (not a version parameter) determines which protocol is
 : used: a "queries" array of {conditions:[...]} objects is the 1.0-draft
 : shape; a "queries" object (or the request body itself, per the strict 0.2
 : spec) keyed by arbitrary query ids with {query, type, limit} fields is 0.2.
 :)
declare function reconc:reconcile($request as map(*)) {
    let $raw-body := $request?body
    let $body :=
        (: application/x-www-form-urlencoded: body is {"queries": "<json string>"} — the
         : classic OpenRefine 0.2 wire format still used by the local 0.2 test bench. :)
        if ($raw-body?queries instance of xs:string) then
            map { "queries": parse-json($raw-body?queries) }
        else
            $raw-body
    return
        if (map:contains($body, "queries") and $body?queries instance of array(*)) then
            reconc:reconcile-1.0($body)
        else if (map:contains($body, "queries")) then
            reconc:reconcile-0.2($body?queries)
        else
            reconc:reconcile-0.2($body)
};

(:~
 : Suggest entities matching a prefix (auto-completion).
 : GET /api/reconcile/suggest/entity?prefix=...&type=...&limit=...
 :)
declare function reconc:suggest-entity($request as map(*)) {
    let $prefix := $request?parameters?prefix
    let $types := reconc:normalize-types($request?parameters?type)
    let $limit := ($request?parameters?limit, 10)[1]
    let $candidates := reconc:candidates($types, $prefix, $limit, map {})
    return
        map {
            "result": array {
                for $c in $candidates
                return
                    map {
                        "id": $c?id,
                        "name": $c?name,
                        "notable": [ map { "id": $c?type-id, "name": $reconc-config:TYPES?($c?type-id)?name } ]
                    }
            }
        }
};

(:~ All {id, name, value, type-id} properties across all types, or just for one type id if given. :)
declare %private function reconc:properties-for-type($type-id as xs:string?) as map(*)* {
    let $types := if (exists($type-id)) then ($type-id) else map:keys($reconc-config:TYPES)
    for $t in $types
    let $props := $reconc-config:TYPES?($t)?properties
    where exists($props)
    return
        map:for-each($props, function($pid, $pdef) {
            map:merge((map { "id": $pid, "type-id": $t }, $pdef))
        })
};

(:~
 : Suggest properties matching a prefix (auto-completion).
 : GET /api/reconcile/suggest/property?prefix=...&type=...&limit=...
 :)
declare function reconc:suggest-property($request as map(*)) {
    let $prefix := reconc:normalize-text($request?parameters?prefix)
    let $type := $request?parameters?type
    let $limit := ($request?parameters?limit, 20)[1]
    let $matches :=
        for $p in reconc:properties-for-type($type)
        where $prefix eq "" or contains(reconc:normalize-text($p?id), $prefix) or contains(reconc:normalize-text($p?name), $prefix)
        return map { "id": $p?id, "name": $p?name }
    return
        map { "result": array { subsequence($matches, 1, max(($limit, 0))) } }
};

(:~
 : Suggest reconciliation types matching a prefix (auto-completion).
 : GET /api/reconcile/suggest/type?prefix=...&limit=...
 :)
declare function reconc:suggest-type($request as map(*)) {
    let $prefix := reconc:normalize-text($request?parameters?prefix)
    let $limit := ($request?parameters?limit, 20)[1]
    let $matches :=
        map:for-each($reconc-config:TYPES, function($id, $def) {
            if ($prefix eq "" or contains(reconc:normalize-text($id), $prefix) or contains(reconc:normalize-text($def?name), $prefix)) then
                map { "id": $id, "name": $def?name }
            else
                ()
        })
    return
        map { "result": array { subsequence($matches, 1, max(($limit, 0))) } }
};

(:~ Renders the preview/view HTML for a matched entity: the type's own "preview"
 : function-item if configured, otherwise the app's ODD web-transform pipeline
 : (the same one the "registers" profile itself uses) in the type's configured
 : "preview-mode" (default "register-overview"). :)
declare %private function reconc:render-html($request as map(*), $found as map(*)?) as item()* {
    if (empty($found)) then
        <html><head><meta charset="UTF-8"/></head><body><p>Entity not found.</p></body></html>
    else
        let $entity := $found?entity
        let $type-def := $reconc-config:TYPES?($found?type-id)
        return
            if (exists($type-def?preview)) then
                ($type-def?preview)($entity)
            else
                let $odd := head(($request?parameters?odd, $config:default-odd))
                let $mode := head(($type-def?preview-mode, "register-overview"))
                return
                    <html>
                        <head><meta charset="UTF-8"/></head>
                        <body style="font-family: sans-serif; margin: 0.5em;">
                        <div class="reconcile-preview">
                        { ($pm-config:web-transform)($entity, map { "mode": $mode }, $odd) }
                        </div>
                        </body>
                    </html>
};

(:~
 : HTML preview for embedding in an iframe (manifest.preview).
 : GET /api/reconcile/preview?id=...
 :)
declare function reconc:preview($request as map(*)) {
    let $id := $request?parameters?id
    let $found := reconc:entity-by-id($id)
    return
        router:response(200, "text/html", reconc:render-html($request, $found))
};

(:~
 : Entity view (manifest.view): GET /api/reconcile/entity/{id}
 :
 : The entity's type "view" config (see reconcile-config.xql) decides what happens:
 :  - a function item is called directly for full control over the response;
 :  - an xs:string (a "registers" browse-page name) redirects there, but only if
 :    the "registers" profile is actually installed in this app — otherwise falls
 :    through to the same ODD-based preview rendering used when no "view" is
 :    configured at all. This is what lets the shipped defaults (which set
 :    "view": "people"/"places") work whether or not "registers" happens to be
 :    part of the app: reconcile itself only depends on "base10".
 :)
declare function reconc:entity($request as map(*)) {
    let $id := $request?parameters?id
    let $found := reconc:entity-by-id($id)
    return
        if (empty($found)) then
            error($errors:NOT_FOUND, "No reconciled entity with id " || $id)
        else
            let $view := $reconc-config:TYPES?($found?type-id)?view
            return
                if ($view instance of function(*)) then
                    $view($id, $found, $request)
                else if (exists($view) and reconc-config:profile-installed("registers")) then
                    router:response(303, (), (), map { "Location": reconc:site-root($request) || "/" || $view || "/" || $id })
                else
                    router:response(200, "text/html", reconc:render-html($request, $found))
};

(:~ Looks up a property definition by id across all types (property ids are assumed
 : unique across the configured type registry). :)
declare %private function reconc:property-by-id($id as xs:string?) as map(*)? {
    if (empty($id)) then
        ()
    else
        head(reconc:properties-for-type(())[?id = $id])
};

(:~ Builds a data-extension response for the given query, shaped per protocol version
 : ("rows" is an array of {id, properties} in 1.0-draft, an id-keyed object of
 : property-id-keyed value arrays in 0.2). :)
declare %private function reconc:extend-response($query as map(*), $version as xs:string?) as map(*) {
    let $ids := $query?ids?*
    let $properties := $query?properties?*
    let $meta := array {
        for $p in $properties
        let $prop-def := reconc:property-by-id($p?id)
        return map { "id": $p?id, "name": ($prop-def?name, $p?id)[1] }
    }
    let $value-for := function($id as xs:string, $prop-id as xs:string) as xs:string* {
        let $found := reconc:entity-by-id($id)
        (: Scoped to the entity's own type, not reconc:property-by-id's global lookup:
         : property ids only need to be unique *within* a type (see reconcile-config.xql's
         : doc comment) — the shipped defaults now reuse "gnd" for both "person" and
         : "work", each with a different extractor, so picking a property definition
         : without knowing which type the entity actually is would silently apply the
         : wrong one whenever two types share a property id. :)
        let $prop-def := if (exists($found)) then head(reconc:properties-for-type($found?type-id)[?id = $prop-id]) else ()
        return
            if (exists($found) and exists($prop-def)) then
                let $extractor := reconc:resolve-extractor($prop-def?value)
                return
                    for $v in $extractor($found?entity)
                    let $s := string($v)
                    where $s != ""
                    return $s
            else
                ()
    }
    return
        if ($version = "0.2") then
            map {
                "meta": $meta,
                "rows": map:merge(
                    for $id in $ids
                    return
                        map:entry($id, map:merge(
                            for $p in $properties
                            return map:entry($p?id, array { for $v in $value-for($id, $p?id) return map { "str": $v } })
                        ))
                )
            }
        else
            map {
                "meta": $meta,
                "rows": array {
                    for $id in $ids
                    return
                        map {
                            "id": $id,
                            "properties": array {
                                for $p in $properties
                                return
                                    map {
                                        "id": $p?id,
                                        "values": array { for $v in $value-for($id, $p?id) return map { "str": $v } }
                                    }
                            }
                        }
                }
            }
};

(:~
 : Data extension: fetch property values for a batch of entity ids.
 : POST /api/reconcile/extend (1.0-draft canonical path). The classic GET
 : "<endpoint>?extend=..." convention some clients (incl. the local test bench) still
 : use is handled directly in reconc:manifest.
 :)
declare function reconc:extend($request as map(*)) {
    reconc:extend-response($request?body, $request?parameters?version)
};

(:~
 : Data extension property proposal: suggest properties fetchable for a given type.
 : GET /api/reconcile/extend/propose?type=...&limit=...
 :)
declare function reconc:extend-propose($request as map(*)) {
    let $type := $request?parameters?type
    let $limit := ($request?parameters?limit, 20)[1]
    let $props := subsequence(reconc:properties-for-type($type), 1, max(($limit, 0)))
    return
        map:merge((
            map {
                "properties": array { for $p in $props return map { "id": $p?id, "name": $p?name } },
                "limit": $limit
            },
            if (exists($type)) then map { "type": $type } else ()
        ))
};
