// GUI test: reconciling an entity from inside the web annotation editor, against this
// profile's own /api/reconcile endpoint.
//
// Scope: covers the "click an already-tagged entity -> edit -> the reconciliation
// search fires against our endpoint -> a real candidate is shown -> selecting it links
// the entity" click path. Confirmed manually 2026-07-24 (see the
// annotate_reconciliation_client project memory / README_MANUAL_TESTING.md §B3) that
// this exact flow, wired up correctly, previously queried https://api.metagrid.ch/
// instead of localhost -- root cause: tei-publisher-components' createConnectors()
// silently falls back to the unrelated Metagrid connector for ANY unrecognized
// `connector` attribute value (a typo like connector="Reconciliation" instead of the
// exact "ReconciliationService" would trigger this, with no error). These tests are a
// regression guard against exactly that: they assert the actual request URL, not just
// "some request happened".
//
// NOT covered here: tagging a brand-new entity by selecting raw, previously-untagged
// text in the document. That flow drives the browser's native Selection API inside a
// Shadow DOM (pb-view-annotate debounces `selectionchange`/`mouseup` and tracks
// selection state manually -- see pb-view-annotate.js's _selectionChanged), which
// Cypress has no first-class command for; it would need low-level
// cy.window().its('...').invoke('getSelection')-style scripting and is meaningfully
// more fragile than the click-to-edit flow tested here. Worth a follow-up if the
// "create new annotation" path specifically needs coverage.
//
// Uses real demo data (the Karl Barth sermon 27004.xml, "Thurneysen" persName, entity
// id kbga-actors-403) rather than a synthetic fixture -- demo-data is a required
// `extends` for any app running these tests, so this is stable, not incidental
// live-app state, matching the convention already used by this profile's own API tests
// (reconcile.cy.js's Goethe/Dantiscus examples).
describe('Web annotation editor: reconciling an entity against our own endpoint', () => {
  const docPath = 'sermons/27004.xml';
  const annotateUrl = `/${docPath}?template=annotate.html&odd=annotations&view=single`;
  const auth = { username: 'tei', password: 'simple' };

  before(() => {
    // Idempotently wire the "person" authority to our own ReconciliationService
    // connector. The stock annotate profile default is connector="Custom" (GND) for
    // person, not reconciliation -- this is a required one-time app customization for
    // this demo, not optional tuning (see README_TEST_CONTAINER.md §2c/§4).
    const xq = `
      declare namespace html="http://www.w3.org/1999/xhtml";
      let $doc := doc("/db/apps/tp-reconc/templates/pages/annotate.html")
      let $person := $doc//*[local-name() = 'pb-authority'][@name = 'person']
      return
        if ($person/@connector = "ReconciliationService") then "already-wired"
        else (
          update replace $person with
            <pb-authority connector="ReconciliationService" name="person"
              endpoint="/exist/apps/tp-reconc/api/reconcile" type="person" edit=""/>,
          "updated"
        )
    `;
    cy.request({
      method: 'POST',
      url: 'http://localhost:8080/exist/rest/db',
      auth,
      headers: { 'Content-Type': 'application/xml' },
      body: `<query xmlns="http://exist.sourceforge.net/NS/exist" wrap="no"><text><![CDATA[${xq}]]></text></query>`,
    }).its('status').should('eq', 200);
  });

  it('editing a tagged person entity queries this app\'s own /api/reconcile, not an external service', () => {
    cy.intercept('**/api/reconcile**').as('reconcile');

    cy.visit(annotateUrl, { auth });
    cy.wait(3000); // let pb-view-annotate finish its initial render before interacting
    cy.get('.annotation.authority').contains('Thurneysen').scrollIntoView().click({ force: true });
    cy.wait(500); // Tippy.js popup mount
    cy.get('paper-icon-button[icon="icons:create"]').click({ force: true });

    cy.wait('@reconcile').then((interception) => {
      // The actual regression this guards: a misconfigured/unrecognized connector
      // name silently falls back to https://api.metagrid.ch/ with no error.
      expect(interception.request.url).to.match(/^http:\/\/localhost:8080\/exist\/apps\/tp-reconc\/api\/reconcile/);
      expect(interception.request.url).not.to.include('metagrid');
      expect(interception.response.statusCode).to.eq(200);
      // The connector's own query-id counter (q1, q2, ...) isn't stable across runs
      // (it can fire more than one debounced query while the search field is
      // pre-filled), so read whichever single query key the response actually used
      // rather than assuming "q1".
      const [query] = Object.values(interception.response.body || {});
      const candidates = query?.result || [];
      if (candidates.length === 0) {
        // an early, still-empty-query debounce tick can legitimately return zero
        // candidates; the UI-level assertion below is the real check that a usable
        // result eventually renders.
        return;
      }
      expect(candidates[0].id).to.eq('kbga-actors-403');
      expect(candidates[0].name).to.include('Thurneysen');
    });

    cy.contains('Thurneysen, Eduard (1888-1974)').should('be.visible');
  });

  it('selecting the returned candidate links the entity to that candidate\'s id', () => {
    cy.intercept('**/api/reconcile**').as('reconcile');

    cy.visit(annotateUrl, { auth });
    cy.wait(3000);
    cy.get('.annotation.authority').contains('Thurneysen').scrollIntoView().click({ force: true });
    cy.wait(500);
    cy.get('paper-icon-button[icon="icons:create"]').click({ force: true });
    cy.wait('@reconcile');

    cy.contains('Thurneysen, Eduard (1888-1974)').click({ force: true });
    cy.wait(1000); // selecting a candidate triggers a save round-trip (annotations/occurrences)

    // The "Annotation Details" panel shows the linked entity's id inside an <input>
    // value, not as plain text content -- cy.contains() only matches rendered text
    // nodes, so check input values directly instead.
    cy.get('input').should(($inputs) => {
      const values = [...$inputs].map((el) => el.value);
      expect(values, 'input values on the page').to.include('kbga-actors-403');
    });
  });
});
