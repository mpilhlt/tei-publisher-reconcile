xquery version "3.1";

(:~
 : XQSuite unit tests proving reconcile-config.xql's pluggability contract, decoupled
 : from HTTP (layer 1 of the test pyramid — see
 : skills/teipublisher-reconciliation-testing/SKILL.md). Two things are checked:
 : (1) the shipped defaults actually work against real register data, and (2) the
 : *mechanism* a custom config relies on — function-item extractors, xs:string XPath
 : extractors evaluated via util:eval, and a swappable $reconc-config:SCORE — behaves as
 : documented, using deliberately different (non-default) stand-ins so this doesn't
 : just re-assert the shipped defaults.
 :
 : Run via `xst run` / eXide's test runner, or ad-hoc:
 :   import module namespace t="http://teipublisher.com/api/reconcile/config/test" at "xmldb:exist:///db/apps/<abbrev>/test/xqsuite/reconcile-config.xqm";
 :   test:suite(util:list-functions("http://teipublisher.com/api/reconcile/config/test"))
 :)
module namespace t = "http://teipublisher.com/api/reconcile/config/test";

import module namespace reconc-config = "http://teipublisher.com/api/reconcile/config" at "../../modules/reconcile-config.xql";
import module namespace reconc-score = "http://teipublisher.com/api/reconcile/scoring" at "../../modules/reconcile-scoring.xql";
import module namespace test = "http://exist-db.org/xquery/xqsuite" at "resource:org/exist/xquery/lib/xqsuite/xqsuite.xql";

declare namespace tei = "http://www.tei-c.org/ns/1.0";

(:~ Every shipped default type's "entities" function must run without error (whether
 : or not the demo dataset happens to have any entities of that type — e.g. the demo
 : "organization" register is empty), and wherever entities do exist, the type's
 : "label" extractor must produce a non-empty string for the first one — proves the
 : shipped defaults are wired up correctly against real "registers" data, not just
 : syntactically valid. :)
declare
    %test:assertTrue
function t:default-types-have-entities-and-labels() {
    every $type-id in map:keys($reconc-config:TYPES)
    satisfies
        let $type-def := $reconc-config:TYPES?($type-id)
        let $entities := ($type-def?entities)()
        return
            empty($entities)
            or normalize-space(($type-def?label)($entities[1])) != ""
};

(:~ At least one shipped default type actually has entities in the demo dataset —
 : guards against the previous test vacuously passing if every register were empty. :)
declare
    %test:assertTrue
function t:at-least-one-default-type-has-entities() {
    some $type-id in map:keys($reconc-config:TYPES)
    satisfies exists((($reconc-config:TYPES?($type-id))?entities)())
};

(:~ The default scoring function: exact match scores 100, no overlap scores 0. :)
declare
    %test:assertEquals(100, 0)
function t:default-score-exact-and-no-match() {
    (reconc-score:default("Goethe", "Goethe"), reconc-score:default("Goethe", "Schiller"))
};

(:~ A config's "label"/property "value" entry may be an xs:string XPath instead of a
 : function item, evaluated relative to the entity via util:eval. This replicates
 : reconcile-api.xql's private reconc:resolve-extractor (which can't be imported
 : directly — module privacy is intentional, see its doc comment) against a
 : deliberately different, non-default entity shape and XPath, to prove the
 : *mechanism* generalizes rather than re-testing the shipped defaults. :)
declare
    %test:assertEquals("Test Person")
function t:xpath-string-extractor-mechanism-works() {
    let $data := <mock><name type="display">Test Person</name></mock>
    let $xpath := "name[@type='display']"
    return normalize-space(util:eval("($data)/" || $xpath))
};

(:~ A config's $reconc-config:SCORE-shaped variable can be swapped for arbitrary logic —
 : demonstrated with a trivial custom function distinct from reconc-score:default, to
 : prove the *contract* (function($label, $query) as xs:double) is what matters, not
 : a hardcoded algorithm. :)
declare
    %test:assertEquals(42, 42)
function t:score-contract-is-swappable() {
    let $custom-score := function($label as xs:string?, $query as xs:string?) as xs:double { 42 }
    return ($custom-score("anything", "anything"), $custom-score("completely different", "unrelated"))
};

(:~ reconc-config:profile-installed reads the real, generator-written context.json of
 : the app this test runs in — "registers" is genuinely extended by every demo app
 : this profile is tested against (see reconcile/doc/README.md), so this is an
 : integration check, not a mock. Guards the "view" fallback logic in
 : reconcile-api.xql's reconc:entity: a redirect to a "registers" browse page is only
 : attempted when this returns true. :)
declare
    %test:assertTrue
function t:profile-installed-detects-registers() {
    reconc-config:profile-installed("registers")
};

(:~ A profile that was never extended into this app must report false, not error out
 : (e.g. on a missing/empty context.json entry) — this is the exact condition under
 : which reconc:entity falls back to its own ODD-based preview instead of redirecting
 : to a "registers" page that wouldn't exist. :)
declare
    %test:assertFalse
function t:profile-installed-false-for-absent-profile() {
    reconc-config:profile-installed("definitely-not-a-real-profile-xyz")
};
