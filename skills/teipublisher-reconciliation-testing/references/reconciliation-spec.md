# Reconciliation Service API: endpoints, 0.2 vs 1.0, schemas

Authoritative sources:
- Spec hub: https://reconciliation-api.github.io/specs/ (1.0 draft:
  https://reconciliation-api.github.io/specs/1.0-draft/)
- Specs repo (HTML + JSON Schemas + valid/invalid example fixtures):
  https://github.com/reconciliation-api/specs
- A worked implementation to compare against: https://github.com/drkane/datasette-reconcile

Confirm exact request/response shapes against the spec version you target and against the manifest
your own service returns. The maps below are orientation, not a substitute for the spec.

## Endpoint map (orientation)

The service is rooted at a single endpoint (in our app: `/exist/apps/<abbrev>/api/reconcile`).
Sub-services are discovered from the **manifest**, not configured separately.

- **Manifest** — `GET` the endpoint with **no params** → JSON manifest: `name`, `identifierSpace`,
  `schemaSpace`, `versions` (which protocol versions you support — each testbench keys off this),
  `defaultTypes`, `view.url`, and optional sub-services (`suggest`, `preview`, `extend`).
- **Reconcile** — `POST` a query batch → a result batch keyed by the same query ids; each result
  is an array of candidates `{id, name, type, score, match}` sorted by descending score.
- **Suggest** (optional) — entity / type / property auto-completion, advertised under `suggest`.
- **Preview** (optional) — embeddable HTML preview, advertised under `preview`.
- **Data extension** (optional) — `extend` (property values for ids) + a property-proposal
  endpoint, advertised under `extend`.

## What differs between 0.2 and 1.0 (and bites tests)

- **CORS**: 1.0 makes CORS **mandatory** (JSONP optional); 0.2 recommends CORS with JSONP as the
  older fallback. In our platform CORS is handled centrally (see jinks-profiles.md) — the practical
  concern is that the caller's `Origin` is in `config:origin-whitelist` (localhost is, by default).
- **`versions`** in the manifest announces supported versions; advertise **both** if you intend to
  pass both testbenches, and make each version's responses actually conform.
- **Query shape**: 1.0 restricts a query to a single type and **removed `type_strict`**; result and
  data-extension formats were revised. Don't carry 0.x request quirks into 1.0 handlers.
- **Sub-service endpoints** are manifest-derived in 1.0 (no separate configuration).

Decide early how your handlers distinguish versions (e.g. manifest `versions` + version-aware
response building) and test both end-to-end.

## JSON Schema files (vendor these for validation)

The specs repo provides schemas per version. For the targeted versions:

- **0.2** → `specs/0.2/schemas/`
- **1.0** → `specs/1.0-draft/schemas/` (the published 1.0 work; the 1.0 testbench tracks it)

Files in each: `manifest.json`, `reconciliation-query-batch.json`,
`reconciliation-result-batch.json`, `suggest-entities-response.json`,
`suggest-properties-response.json`, `suggest-types-response.json`, `data-extension-query.json`,
`data-extension-response.json`, `data-extension-property-proposal.json`, `type.json`
(0.2 also has `openapi.json`; 1.0-draft adds `dir.json`, `lang.json`).

Validate inside Cypress with `cy.validateSchema(schema)` (see cypress-testing.md). For a quick
out-of-harness check, AJV works too:

```bash
npm i -g ajv-cli ajv-formats          # or: pipx install check-jsonschema
ajv validate -c ajv-formats -s 1.0/manifest.json -d captured/manifest.json
ajv validate -c ajv-formats -s 1.0/reconciliation-result-batch.json -d captured/reconcile.json
```

Each schema directory ships `examples/<name>/valid/*` and `.../invalid/*` payloads — validate those
first to confirm your wiring accepts the valid ones and rejects the invalid ones before trusting it
against your own responses.
