xquery version "3.1";

(:~
 : Reconciliation type registry — the single place to add, remove, or customize what
 : "kinds of things" this service reconciles. Sensible defaults ship here for the
 : typical case (person/place/organization/work against the "registers" profile's
 : local authority files); edit this file directly to point at different content, a
 : different vocabulary, or an entirely different scoring algorithm.
 :
 : Jinks tracks this file like any other: a fresh `jinks create` copies these
 : defaults in; if you edit it locally afterwards, a later `jinks update` will
 : detect the change and report a *conflict* instead of silently overwriting your
 : customization (see reconcile/doc/README.md for details).
 :
 : Each entry in $reconc-config:TYPES is a map:
 :   name          - display name, used in the manifest and suggest/type
 :   view          - (optional) a "registers" profile browse-page name (e.g. "people")
 :                   to redirect to for GET /api/reconcile/entity/{id}; omit if this
 :                   type has no dedicated browse page (the preview renderer is used
 :                   as a fallback instead)
 :   entities      - function() as element()* — returns every candidate entity node
 :                   for this type. Always a function (not an XPath string): the
 :                   context — which collection, relative to what — is inherently
 :                   ambiguous for a bare selection XPath, so a closure is both
 :                   clearer and no more work to write.
 :   label         - the human-readable label for a matched entity. Either a
 :                   function($entity as element()) as xs:string, or an xs:string
 :                   containing an XPath expression evaluated with the entity as
 :                   context (e.g. ".//tei:persName[@type='main'][1]") — see
 :                   reconc:resolve-extractor in reconcile-api.xql.
 :   preview-mode  - (optional) the ODD web-transform mode used to render this
 :                   type's default HTML preview (GET /api/reconcile/preview and the
 :                   /entity/{id} fallback). Defaults to "register-overview" — the
 :                   same mode the "registers" profile itself uses. Ignored if
 :                   "preview" (below) is given.
 :   preview       - (optional) function($entity as element()) as node() — fully
 :                   overrides preview rendering for this type instead of using the
 :                   ODD transform.
 :   properties    - map of property-id -> map { name, value }, where "value" is
 :                   either a function($entity as element()) as xs:string*, or an
 :                   xs:string XPath (same rules as "label"). Drives
 :                   /suggest/property, /extend and /extend/propose.
 :)
module namespace reconc-config = "http://teipublisher.com/api/reconcile/config";

import module namespace config = "http://www.tei-c.org/tei-simple/config" at "config.xqm";
import module namespace reconc-score = "http://teipublisher.com/api/reconcile/scoring" at "reconcile-scoring.xql";

declare namespace tei = "http://www.tei-c.org/ns/1.0";

declare variable $reconc-config:TYPES := map {
    "person": map {
        "name": "Person",
        "view": "people",
        "entities": function() as element()* {
            collection($config:register-root)/id($config:register-map?person?id)//tei:person[@xml:id]
        },
        "label": function($e as element()) as xs:string {
            normalize-space(($e/tei:persName[@type = "main"], $e/tei:persName, $e)[1])
        },
        "preview-mode": "register-overview",
        "properties": map {
            "gender": map { "name": "Gender", "value": function($e as element()) as xs:string* { normalize-space($e/tei:gender[1]) } },
            "note": map { "name": "Biographical note", "value": function($e as element()) as xs:string* { normalize-space($e/tei:note[1]) } }
        }
    },
    "place": map {
        "name": "Place",
        "view": "places",
        "entities": function() as element()* {
            collection($config:register-root)/id($config:register-map?place?id)//tei:place[@xml:id]
        },
        "label": function($e as element()) as xs:string {
            normalize-space(($e/tei:placeName[@type = "main"], $e/tei:placeName, $e)[1])
        },
        "preview-mode": "register-overview",
        "properties": map {
            "geo": map { "name": "Coordinates", "value": function($e as element()) as xs:string* { normalize-space($e/tei:location/tei:geo[1]) } },
            "type": map { "name": "Place type", "value": function($e as element()) as xs:string* { $e/@type/string() } }
        }
    },
    "organization": map {
        "name": "Organization",
        "entities": function() as element()* {
            collection($config:register-root)/id($config:register-map?organization?id)//tei:org[@xml:id]
        },
        "label": function($e as element()) as xs:string {
            normalize-space(($e/tei:orgName[@type = "main"], $e/tei:orgName, $e)[1])
        },
        "preview-mode": "register-overview",
        "properties": map {}
    },
    "work": map {
        "name": "Work",
        "entities": function() as element()* {
            collection($config:register-root)/id($config:register-map?work?id)//tei:bibl[@xml:id]
        },
        "label": function($e as element()) as xs:string {
            normalize-space(($e/tei:title[@type = "main"], $e/tei:title, $e)[1])
        },
        "preview-mode": "register-overview",
        "properties": map {
            "author": map { "name": "Author", "value": function($e as element()) as xs:string* { normalize-space($e/tei:author[1]) } }
        }
    }
};

(:~ Matching/ranking function: given a candidate's label and the query string,
 : return a score between 0 (no match) and 100 (perfect match). Point this at your
 : own function item to change the algorithm (fuzzy matching, external NER-based
 : scoring, weighting by property matches, etc.) — see reconc-score:default for the
 : signature to match. :)
declare variable $reconc-config:SCORE := reconc-score:default#2;
