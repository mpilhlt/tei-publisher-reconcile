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
    // connector, and configure `fields` (see tei-publisher-components' Registry.
    // buildProperties/parseFieldsConfig) so a selected match's escaped name, id, and
    // (fetched via /extend) GND identifier land in three separate output attributes
    // instead of the id alone going to the reference/key field -- this is a required
    // one-time app customization for this demo, not optional tuning (see
    // README_TEST_CONTAINER.md §2c/§4). Setting `fields` here does not break the
    // existing id-only assertions below: they only check that SOME input holds the
    // expected id, which the new @ref-mapped hidden field still satisfies.
    const xq = `
      declare namespace html="http://www.w3.org/1999/xhtml";
      let $doc := doc("/db/apps/tp-reconc/templates/pages/annotate.html")
      let $person := $doc//*[local-name() = 'pb-authority'][@name = 'person']
      return
        if ($person/@fields = "key=label,ref=id,gnd=extend:gnd") then "already-wired"
        else (
          update replace $person with
            <pb-authority connector="ReconciliationService" name="person"
              endpoint="/exist/apps/tp-reconc/api/reconcile" type="person" edit=""
              fields="key=label,ref=id,gnd=extend:gnd"/>,
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

    // Select via the dedicated "link to" button, not the candidate's label text: when
    // the service's manifest resolves a view URL for the candidate, the label is ALSO
    // wrapped in its own <a href> (opens the entity's view page in a new tab) --
    // cy.contains(label).click() is ambiguous between the two and can hit the link
    // instead of actually selecting the candidate. The button carries a stable
    // title="link to" regardless of whether a view link is present.
    cy.contains('li', 'Thurneysen, Eduard (1888-1974)').find('button[title="link to"]').click({ force: true });
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

// Regression coverage for the general field-mapping mechanism (see
// tei-publisher-components' Registry.buildProperties/parseFieldsConfig, and
// README_MANUAL_TESTING.md §B3 / the annotate_reconciliation_client project memory):
// an admin can configure, via the `fields` attribute set in this file's own before()
// hook above, which of a match's fields end up in which output attribute, instead of
// only ever the id going to a single reference/key attribute. Uses a different demo
// entity than the tests above ("Sailer, Hieronymus" / gnd-137224435, in
// demo/CIDTC-3823-cortez.xml) specifically because it has a real, non-empty GND
// identifier available via /extend, letting this test also exercise the
// `extend:propertyId` field source end-to-end, not just id/label.
describe('Web annotation editor: mapping a match\'s fields to output attributes', () => {
  const annotateUrl = '/demo/CIDTC-3823-cortez.xml?template=annotate.html&odd=annotations&view=single';
  const auth = { username: 'tei', password: 'simple' };

  it('writes the escaped name, id, and an /extend-fetched property to three separate attributes', () => {
    cy.visit(annotateUrl, { auth });
    cy.wait(4000);
    cy.get('.annotation.authority').contains('Ger').scrollIntoView().click({ force: true });
    cy.wait(500);
    cy.get('paper-icon-button[icon="icons:create"]').click({ force: true });
    cy.wait(1000);

    // The pencil-click auto-fills the search box with the clicked span's own visible
    // text ("Gerónimo Sailer", given-name-first), which genuinely doesn't score a
    // match against this entity's "Sailer, Hieronymus" (surname-first) label via
    // either /suggest/entity or the full /reconcile endpoint -- confirmed directly
    // against both endpoints, not a bug in this test. Type an explicit search term
    // that does match instead of relying on the auto-filled one.
    cy.get('pb-authority-lookup').shadow().find('input#query').clear().type('Sailer');
    cy.wait(1500);
    cy.contains('li', 'Sailer, Hieronymus').find('button[title="link to"]').click({ force: true });
    cy.wait(1500);

    cy.get('input[name="key"]').should('have.value', 'Sailer-Hieronymus');
    cy.get('input[name="ref"]').should('have.value', 'gnd-137224435');
    cy.get('input[name="gnd"]').should('have.value', 'https://d-nb.info/gnd/137224435');
  });
});
