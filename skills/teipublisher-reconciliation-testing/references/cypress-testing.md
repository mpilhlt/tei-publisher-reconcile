# Cypress testing harness (the project's native API tests)

TEI Publisher v10 tests with **Cypress**, organised per profile. Your reconciliation tests belong
in `profiles/reconcile/test/cypress/e2e/api/reconcile.cy.js` (and the client tests, if any, under
`profiles/annotate/test/cypress/e2e/gui/`). This is the same approach as the rest of the codebase,
so prefer it over a bespoke curl harness for integration + schema conformance.

Sources:
- Cypress: https://docs.cypress.io
- cypress-ajv-schema-validator: https://www.npmjs.com/package/cypress-ajv-schema-validator
- Reconciliation JSON Schemas: https://github.com/reconciliation-api/specs

## What's already provided (base10 support)

`profiles/base10/test/cypress/support/commands.js` imports `cypress-ajv-schema-validator` and
defines custom commands you should reuse:

- `cy.api(opts)` — like `cy.request`, but injects an `Origin` header equal to the configured
  `baseUrl` origin. Because `baseUrl` is `http://localhost:…`, requests are **CORS-clean against
  the stock origin-whitelist**. Use this, not raw `cy.request`, for API calls.
- `cy.login(fixture?)`, `cy.logout()` — session handling.
- `cy.uploadXml(filename, xml, opts?)` — PUT a document via `/api/document/...`.
- `cy.validateSchema(schema[, path])` — from the AJV plugin; validates the response body against a
  JSON Schema (chainable on a request). A manual `cy.validateJsonSchema(ajv, schema, data, file)`
  also exists as a fallback.

Run the suite from the app/profile context with `npx cypress run` (`npm test`). Point
`cypress.config.cjs` `baseUrl` at your generated app: `http://localhost:8080/exist/apps/<abbrev>`.
The repo's default `baseUrl` is the jinks app; change it to your app when testing reconciliation.

## Validating against the reconciliation JSON Schemas

Vendor the official schemas for the versions you target into the profile's fixtures, e.g.:

```
profiles/reconcile/test/cypress/fixtures/schemas/
├── 0.2/manifest.json
├── 0.2/reconciliation-result-batch.json
├── 1.0/manifest.json            # from the specs repo's 1.0-draft/schemas
└── 1.0/reconciliation-result-batch.json
```

(Exact filenames available per version: `manifest.json`, `reconciliation-query-batch.json`,
`reconciliation-result-batch.json`, `suggest-entities-response.json`,
`suggest-properties-response.json`, `suggest-types-response.json`, `data-extension-query.json`,
`data-extension-response.json`, `data-extension-property-proposal.json`, `type.json`. See
`references/reconciliation-spec.md`.)

A reconciliation API test then looks like `assets/reconcile.cy.js.example`:

```js
describe('reconciliation API (1.0)', () => {
  let resultSchema
  before(() => cy.fixture('schemas/1.0/reconciliation-result-batch.json').then(s => { resultSchema = s }))

  it('returns a schema-valid manifest on GET (no params)', () => {
    cy.fixture('schemas/1.0/manifest.json').then((manifestSchema) => {
      cy.api({ url: '/api/reconcile' })
        .validateSchema(manifestSchema)
        .its('status').should('eq', 200)
    })
  })

  it('returns a schema-valid result batch on POST', () => {
    cy.api({
      method: 'POST',
      url: '/api/reconcile',
      headers: { 'Content-Type': 'application/json' },
      body: { queries: { q0: { query: 'Goethe' } } },
    })
      .validateSchema(resultSchema)
      .then(({ status, body }) => {
        expect(status).to.eq(200)
        expect(body).to.have.property('q0')
        expect(body.q0.result).to.be.an('array')
      })
  })
})
```

Repeat the suite (or parameterise it) for **both 0.2 and 1.0**, since the response formats differ
(query shape, `type_strict` removed in 1.0, etc. — see the spec reference). The specs repo also
ships `examples/.../valid` and `.../invalid` fixtures you can use to sanity-check that your schema
wiring actually rejects bad payloads.

## XQSuite (optional, for pure functions)

For reusable XQuery functions (scoring, query/limit/type parsing, manifest assembly), eXist's
in-database XQSuite is a fast unit layer: annotate test functions with `%test:assertEquals` etc.
and run `test:suite(util:list-functions("…"))` (e.g. via `xst run`). Keep such logic behind plain
functions so it is testable without HTTP; let Cypress cover the wired routes.
