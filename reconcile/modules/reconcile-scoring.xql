xquery version "3.1";

(:~
 : Default matching/ranking algorithms for the reconcile profile. Public and
 : composable on purpose: a customized reconcile-config.xql can point
 : $reconc-config:SCORE at reconc-score:default#2 directly, or wrap/combine it with
 : its own logic (e.g. "call the default, then boost exact-language matches").
 :)
module namespace reconc-score = "http://teipublisher.com/api/reconcile/scoring";

declare %private function reconc-score:normalize-text($s as xs:string?) as xs:string {
    lower-case(normalize-space($s))
};

(:~
 : Simple 0-100 similarity score between a candidate label and the query string:
 : 100 for an exact (case/whitespace-insensitive) match, a length-ratio score for
 : substring containment either way, otherwise a token-overlap ratio, or 0 if
 : nothing at all is shared.
 :)
declare function reconc-score:default($label as xs:string?, $query as xs:string?) as xs:double {
    let $l := reconc-score:normalize-text($label)
    let $q := reconc-score:normalize-text($query)
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
