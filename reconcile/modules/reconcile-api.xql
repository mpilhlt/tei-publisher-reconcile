xquery version "3.1";

module namespace recon="http://teipublisher.com/api/reconcile";

import module namespace config="http://www.tei-c.org/tei-simple/config" at "config.xqm";
import module namespace router="http://e-editiones.org/roaster";
import module namespace errors="http://e-editiones.org/roaster/errors";

declare namespace tei="http://www.tei-c.org/ns/1.0";

(:~ Maps a reconciliation type id to the local name of the TEI element it is stored as. :)
declare variable $recon:TYPE_ELEMENTS := map {
    "person": "person",
    "place": "place",
    "organization": "org",
    "work": "bibl"
};

declare variable $recon:TYPE_LABELS := map {
    "person": "Person",
    "place": "Place",
    "organization": "Organization",
    "work": "Work"
};

(:~ Real page under the "registers" profile a type's entities can be browsed at, if any. :)
declare variable $recon:TYPE_VIEWS := map {
    "person": "people",
    "place": "places"
};

(:~ A small demo property catalog per reconciliation type, used by /suggest/property,
 : /extend and /extend/propose. Each property is {id, name, xpath} where xpath is a
 : function extracting the raw value(s) from a matched entity element. :)
declare variable $recon:PROPERTIES := map {
    "person": (
        map { "id": "gender", "name": "Gender", "value": function($e as element()) { normalize-space($e/tei:gender[1]) } },
        map { "id": "note", "name": "Biographical note", "value": function($e as element()) { normalize-space($e/tei:note[1]) } }
    ),
    "place": (
        map { "id": "geo", "name": "Coordinates", "value": function($e as element()) { normalize-space($e/tei:location/tei:geo[1]) } },
        map { "id": "type", "name": "Place type", "value": function($e as element()) { $e/@type/string() } }
    ),
    "organization": (),
    "work": (
        map { "id": "author", "name": "Author", "value": function($e as element()) { normalize-space($e/tei:author[1]) } }
    )
};

(:~ All {id, name} properties across all types, or just for one type id if given. :)
declare %private function recon:properties-for-type($type-id as xs:string?) as map(*)* {
    let $types := if (exists($type-id)) then ($type-id) else map:keys($recon:PROPERTIES)
    for $t in $types
    for $prop in $recon:PROPERTIES($t)
    return $prop
};

declare %private function recon:site-root($request as map(*)) as xs:string {
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

declare %private function recon:base-url($request as map(*)) as xs:string {
    recon:site-root($request) || "/api/reconcile"
};

(:~ All registered entities for a reconciliation type id, e.g. "person". :)
declare %private function recon:entities($type-id as xs:string) as element()* {
    let $reg := $config:register-map($type-id)
    let $elt-name := $recon:TYPE_ELEMENTS($type-id)
    return
        if (exists($reg) and exists($elt-name)) then
            collection($config:register-root)/id($reg?id)//*[local-name() = $elt-name][@xml:id]
        else
            ()
};

(:~ Finds a single entity by id across all reconciliation types. Returns a map
 : {entity, type-id}, or the empty sequence if no type's register contains it. :)
declare %private function recon:entity-by-id($id as xs:string) as map(*)? {
    let $match :=
        for $type-id in map:keys($recon:TYPE_ELEMENTS)
        let $entity := recon:entities($type-id)[@xml:id = $id]
        where exists($entity)
        return map { "entity": $entity, "type-id": $type-id }
    return head($match)
};

(:~ Human-readable label for a register entity, regardless of its concrete element type. :)
declare %private function recon:label($entity as element()) as xs:string {
    let $name :=
        if ($entity/tei:persName) then
            ($entity/tei:persName[@type = "main"], $entity/tei:persName)[1]
        else if ($entity/tei:placeName) then
            ($entity/tei:placeName[@type = "main"], $entity/tei:placeName)[1]
        else if ($entity/tei:orgName) then
            ($entity/tei:orgName[@type = "main"], $entity/tei:orgName)[1]
        else if ($entity/tei:title) then
            ($entity/tei:title[@type = "main"], $entity/tei:title)[1]
        else
            ()
    return
        normalize-space(if (exists($name)) then $name else $entity)
};

declare %private function recon:normalize-text($s as xs:string?) as xs:string {
    lower-case(normalize-space($s))
};

(:~ Simple 0-100 similarity score between a candidate label and the query string. :)
declare %private function recon:score($label as xs:string?, $query as xs:string?) as xs:double {
    let $l := recon:normalize-text($label)
    let $q := recon:normalize-text($query)
    return
        if ($q eq "" or $l eq "") then
            0
        else if ($l eq $q) then
            100
        else if (contains($l, $q) or contains($q, $l)) then
            100.0 * (2 * min((string-length($l), string-length($q)))) div (string-length($l) + string-length($q))
        else
            let $l-tokens := tokenize($l, "\s+")
            let $q-tokens := tokenize($q, "\s+")
            let $shared := count(distinct-values($q-tokens[. = $l-tokens]))
            return
                if ($shared eq 0) then
                    0
                else
                    100.0 * (2 * $shared) div (count($l-tokens) + count($q-tokens))
};

(:~ Reads a reconciliation "type" value, which may be absent, a single string, or an array of strings. :)
declare %private function recon:normalize-types($type) as xs:string* {
    if (empty($type)) then
        ()
    else if ($type instance of array(*)) then
        $type?*
    else
        $type
};

(:~ Find and score candidates for a query string, restricted to the given type ids (all default types if empty). :)
declare %private function recon:candidates($type-ids as xs:string*, $query as xs:string?, $limit as xs:integer) as map(*)* {
    let $types := if (empty($type-ids)) then map:keys($recon:TYPE_ELEMENTS) else $type-ids
    let $scored :=
        for $type-id in $types
        for $entity in recon:entities($type-id)
        let $label := recon:label($entity)
        let $score := recon:score($label, $query)
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

declare %private function recon:format-candidate($candidate as map(*)) as map(*) {
    map {
        "id": $candidate?id,
        "name": $candidate?name,
        "score": $candidate?score,
        "match": $candidate?score >= 95,
        "type": [
            map {
                "id": $candidate?type-id,
                "name": $recon:TYPE_LABELS($candidate?type-id)
            }
        ]
    }
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
declare function recon:manifest($request as map(*)) {
    let $extend-param := $request?parameters?extend
    return
        if (exists($extend-param) and normalize-space($extend-param) != "") then
            (: Classic (pre-1.0) data-extension convention: GET the service root with an
             : "extend" query parameter, still used by the local reconciliation test bench's
             : data-extension tab. See recon:extend. :)
            recon:extend-response(parse-json($extend-param), $request?parameters?version)
        else
            recon:manifest-response($request)
};

declare %private function recon:manifest-response($request as map(*)) {
    let $version := $request?parameters?version
    let $base := recon:base-url($request)
    let $default-types := array {
        map:for-each($recon:TYPE_LABELS, function($id, $name) { map { "id": $id, "name": $name } })
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
declare %private function recon:query-text-from-conditions($query as map(*)) as xs:string? {
    let $condition := $query?conditions?*[?matchType = "name"][1]
    let $value := $condition?propertyValue
    return
        if ($value instance of map(*)) then
            ($value?name, $value?id)[1]
        else
            $value
};

declare %private function recon:reconcile-1.0($body as map(*)) as map(*) {
    let $queries := $body?queries?*
    return
        map {
            "results": array {
                for $query in $queries
                let $text := recon:query-text-from-conditions($query)
                let $limit := ($query?limit, 10)[1]
                let $types := recon:normalize-types($query?type)
                let $candidates := recon:candidates($types, $text, $limit)
                return
                    map {
                        "candidates": array { for $c in $candidates return recon:format-candidate($c) }
                    }
            }
        }
};

declare %private function recon:reconcile-0.2($query-map as map(*)) as map(*) {
    map:merge(
        for $key in map:keys($query-map)
        let $query := $query-map($key)
        let $text := $query?query
        let $limit := ($query?limit, 10)[1]
        let $types := recon:normalize-types($query?type)
        let $candidates := recon:candidates($types, $text, $limit)
        return
            map:entry($key, map {
                "result": array { for $c in $candidates return recon:format-candidate($c) }
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
declare function recon:reconcile($request as map(*)) {
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
            recon:reconcile-1.0($body)
        else if (map:contains($body, "queries")) then
            recon:reconcile-0.2($body?queries)
        else
            recon:reconcile-0.2($body)
};

(:~
 : Suggest entities matching a prefix (auto-completion).
 : GET /api/reconcile/suggest/entity?prefix=...&type=...&limit=...
 :)
declare function recon:suggest-entity($request as map(*)) {
    let $prefix := $request?parameters?prefix
    let $types := recon:normalize-types($request?parameters?type)
    let $limit := ($request?parameters?limit, 10)[1]
    let $candidates := recon:candidates($types, $prefix, $limit)
    return
        map {
            "result": array {
                for $c in $candidates
                return
                    map {
                        "id": $c?id,
                        "name": $c?name,
                        "notable": [ map { "id": $c?type-id, "name": $recon:TYPE_LABELS($c?type-id) } ]
                    }
            }
        }
};

(:~
 : Suggest properties matching a prefix (auto-completion).
 : GET /api/reconcile/suggest/property?prefix=...&type=...&limit=...
 :)
declare function recon:suggest-property($request as map(*)) {
    let $prefix := recon:normalize-text($request?parameters?prefix)
    let $type := $request?parameters?type
    let $limit := ($request?parameters?limit, 20)[1]
    let $matches :=
        for $p in recon:properties-for-type($type)
        where $prefix eq "" or contains(recon:normalize-text($p?id), $prefix) or contains(recon:normalize-text($p?name), $prefix)
        return map { "id": $p?id, "name": $p?name }
    return
        map { "result": array { subsequence($matches, 1, max(($limit, 0))) } }
};

(:~
 : Suggest reconciliation types matching a prefix (auto-completion).
 : GET /api/reconcile/suggest/type?prefix=...&limit=...
 :)
declare function recon:suggest-type($request as map(*)) {
    let $prefix := recon:normalize-text($request?parameters?prefix)
    let $limit := ($request?parameters?limit, 20)[1]
    let $matches :=
        map:for-each($recon:TYPE_LABELS, function($id, $name) {
            if ($prefix eq "" or contains(recon:normalize-text($id), $prefix) or contains(recon:normalize-text($name), $prefix)) then
                map { "id": $id, "name": $name }
            else
                ()
        })
    return
        map { "result": array { subsequence($matches, 1, max(($limit, 0))) } }
};

(:~ Renders a minimal HTML fragment describing an entity, used by /preview and as a
 : fallback for /entity/{id} when the entity's type has no dedicated browse page. :)
declare %private function recon:render-html($found as map(*)?) as element(html) {
    <html>
        <head><meta charset="UTF-8"/></head>
        <body style="font-family: sans-serif; margin: 0.5em;">
        {
            if (empty($found)) then
                <p>Entity not found.</p>
            else
                let $entity := $found?entity
                let $label := recon:label($entity)
                let $type-id := $found?type-id
                let $note := ($entity/tei:note[1], $entity/tei:bibl[1])[1]
                return (
                    <h3>{$label}</h3>,
                    <p><em>{$recon:TYPE_LABELS($type-id)}</em></p>,
                    if (exists($note)) then <p>{normalize-space($note)}</p> else ()
                )
        }
        </body>
    </html>
};

(:~
 : HTML preview for embedding in an iframe (manifest.preview).
 : GET /api/reconcile/preview?id=...
 :)
declare function recon:preview($request as map(*)) {
    let $id := $request?parameters?id
    let $found := recon:entity-by-id($id)
    return
        router:response(200, "text/html", recon:render-html($found))
};

(:~
 : Entity view (manifest.view): redirects to the real registers browse page when the
 : entity's type has one (person, place), otherwise renders a minimal fallback page.
 : GET /api/reconcile/entity/{id}
 :)
declare function recon:entity($request as map(*)) {
    let $id := $request?parameters?id
    let $found := recon:entity-by-id($id)
    return
        if (empty($found)) then
            error($errors:NOT_FOUND, "No reconciled entity with id " || $id)
        else
            let $view := $recon:TYPE_VIEWS($found?type-id)
            return
                if (exists($view)) then
                    router:response(303, (), (), map { "Location": recon:site-root($request) || "/" || $view || "/" || $id })
                else
                    router:response(200, "text/html", recon:render-html($found))
};

(:~ Looks up a property definition by id across all types (property ids are unique in
 : this small demo catalog). :)
declare %private function recon:property-by-id($id as xs:string?) as map(*)? {
    if (empty($id)) then
        ()
    else
        head(recon:properties-for-type(())[?id = $id])
};

(:~ Builds a data-extension response for the given query, shaped per protocol version
 : ("rows" is an array of {id, properties} in 1.0-draft, an id-keyed object of
 : property-id-keyed value arrays in 0.2). :)
declare %private function recon:extend-response($query as map(*), $version as xs:string?) as map(*) {
    let $ids := $query?ids?*
    let $properties := $query?properties?*
    let $meta := array {
        for $p in $properties
        let $prop-def := recon:property-by-id($p?id)
        return map { "id": $p?id, "name": ($prop-def?name, $p?id)[1] }
    }
    let $value-for := function($id as xs:string, $prop-id as xs:string) as xs:string* {
        let $found := recon:entity-by-id($id)
        let $prop-def := recon:property-by-id($prop-id)
        return
            if (exists($found) and exists($prop-def)) then
                ($prop-def?value)($found?entity)[. != ""]
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
 : use is handled directly in recon:manifest.
 :)
declare function recon:extend($request as map(*)) {
    recon:extend-response($request?body, $request?parameters?version)
};

(:~
 : Data extension property proposal: suggest properties fetchable for a given type.
 : GET /api/reconcile/extend/propose?type=...&limit=...
 :)
declare function recon:extend-propose($request as map(*)) {
    let $type := $request?parameters?type
    let $limit := ($request?parameters?limit, 20)[1]
    let $props := subsequence(recon:properties-for-type($type), 1, max(($limit, 0)))
    return
        map:merge((
            map {
                "properties": array { for $p in $props return map { "id": $p?id, "name": $p?name } },
                "limit": $limit
            },
            if (exists($type)) then map { "type": $type } else ()
        ))
};
