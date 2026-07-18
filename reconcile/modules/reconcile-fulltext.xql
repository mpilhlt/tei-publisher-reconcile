xquery version "3.1";

(:~
 : Lucene fuzzy-query helper shared between reconcile-config.xql (whose
 : "fulltext-search" closures build the query string themselves, directly inside
 : their own path expression) and reconcile-api.xql (which only calls those
 : closures, never builds a query itself) — a small standalone module rather than
 : living in either, since api imports config and a helper needed by both would
 : otherwise force a circular import.
 :)
module namespace reconc-fulltext = "http://teipublisher.com/api/reconcile/fulltext";

(:~ Escapes Lucene QueryParser special characters in a raw query token so it can't
 : break out of the field:(...) query string reconc-fulltext:fuzzy-query builds. :)
declare %private function reconc-fulltext:escape-token($token as xs:string) as xs:string {
    replace($token, '([+\-!(){}\[\]^"~*?:\\/&amp;])', '\\$1')
};

(:~ Builds a fuzzy Lucene query string for a full-text pre-filter: every
 : whitespace-separated token of $query gets Lucene's classic QueryParser "~" fuzzy
 : operator, scoped to $field — e.g. field "name", query "Goehte" becomes
 : "name:(goehte~)". Meant to be embedded directly inside an ft:query() predicate
 : that is itself part of the same path expression doing the collection lookup
 : (e.g. "collection(...)//tei:person[ft:query(., reconc-fulltext:fuzzy-query(...))]")
 : — critically *not* applied afterwards as a filter on an already-materialized
 : node sequence, which prevents eXist from using the Lucene index at all (~300x
 : slower in testing against this project's demo data: 3ms vs. 955ms for the same
 : 33-entity collection). Matches found this way still get their final 0-100 score
 : from $reconc-config:SCORE afterwards — Lucene is only used to shortlist
 : candidates cheaply, not to rank them. :)
declare function reconc-fulltext:fuzzy-query($field as xs:string, $query as xs:string) as xs:string {
    let $tokens := tokenize(normalize-space($query), "\s+")[. != ""]
    return
        $field || ":(" || string-join(for $t in $tokens return reconc-fulltext:escape-token($t) || "~", " ") || ")"
};
