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

(:~ Find and score candidates for a query string, restricted to the given type ids (all default types if empty). :)
declare %private function reconc:candidates($type-ids as xs:string*, $query as xs:string?, $limit as xs:integer) as map(*)* {
    let $types := if (empty($type-ids)) then map:keys($reconc-config:TYPES) else $type-ids
    let $scored :=
        for $type-id in $types
        let $type-def := $reconc-config:TYPES?($type-id)
        where exists($type-def)
        for $entity in ($type-def?entities)()
        let $label := reconc:label($entity, $type-id)
        let $score := ($reconc-config:SCORE)($label, $query)
        where $score > 0
        return
            map {
                "id": $entity/@xml:id/string(),
                "name": $label,
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

declare %private function reconc:reconcile-1.0($body as map(*)) as map(*) {
    let $queries := $body?queries?*
    return
        map {
            "results": array {
                for $query in $queries
                let $text := reconc:query-text-from-conditions($query)
                let $limit := ($query?limit, 10)[1]
                let $types := reconc:normalize-types($query?type)
                let $candidates := reconc:candidates($types, $text, $limit)
                return
                    map {
                        "candidates": array { for $c in $candidates return reconc:format-candidate($c) }
                    }
            }
        }
};

declare %private function reconc:reconcile-0.2($query-map as map(*)) as map(*) {
    map:merge(
        for $key in map:keys($query-map)
        let $query := $query-map($key)
        let $text := $query?query
        let $limit := ($query?limit, 10)[1]
        let $types := reconc:normalize-types($query?type)
        let $candidates := reconc:candidates($types, $text, $limit)
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
    let $candidates := reconc:candidates($types, $prefix, $limit)
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
 : Entity view (manifest.view): redirects to the real registers browse page when the
 : entity's type has one configured ("view"), otherwise renders the preview HTML.
 : GET /api/reconcile/entity/{id}
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
                if (exists($view)) then
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
        let $prop-def := reconc:property-by-id($prop-id)
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
