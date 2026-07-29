# TEI Publisher Reconciliation

An [OpenRefine Reconciliation Service API](https://reconciliation-api.github.io/specs/)
implementation for [TEI Publisher](https://teipublisher.com/) v10, plus a matching client
integration for looking up and linking named entities (people, places, organizations, works)
against any reconciliation service — this one included — while annotating a TEI document.

- **Server**: a new Jinks profile, [`reconcile/`](reconcile), implementing both the
  **0.2** and **1.0-draft** versions of the spec from a single endpoint. It reconciles
  against TEI Publisher's own person/place/organization/work authority registers, and
  supports the optional `/preview`, `/suggest/*`, and data-extension (`/extend`) services on
  top of the mandatory match/reconcile endpoint.
- **Client**: an extension of TEI Publisher's `annotate` profile (patches on top of
  [eeditiones/jinks](https://github.com/eeditiones/jinks), see below) that wires a
  reconciliation-service connector into the entity-authority editor — click a `persName`/
  `placeName`/`orgName`/`term`/`bibl` mention, search a reconciliation service by name, and
  link the mention to the returned candidate.
- **Demo image**: a self-contained container with both baked in, so you can try the whole
  thing without setting up a TEI Publisher/Jinks development environment yourself — see
  below.

## Try the demo

The published image bundles a TEI Publisher v10 instance, the `reconcile` profile, and the
patched `annotate` client, with sample data (a small corpus of Karl Barth's sermons and their
person/place authority records) already loaded.

```bash
podman run -d --name tp-reconc-demo -p 8080:8080 \
  ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:latest
# or: docker run -d --name tp-reconc-demo -p 8080:8080 ghcr.io/mpilhlt/tei-publisher-reconcile/tp-reconc-demo:latest
```

First boot takes 30–90 seconds longer than a normal restart — that's the container
generating the app and deploying the profiles. Watch it come up with:

```bash
podman logs -f tp-reconc-demo
```

Once you see `Ready:`, the app is at:

```
http://localhost:8080/exist/apps/tp-reconc
http://localhost:8080/exist/apps/tp-reconc/api/reconcile
```

Point an [OpenRefine](https://openrefine.org/) reconciliation client, or the
[reconciliation-api test bench](https://reconciliation-api.github.io/testbench/1.0/), at that
`/api/reconcile` URL to try the server on its own; or open the app itself and use the
annotation editor to try the client side (see
[`README_MANUAL_TESTING.md`](README_MANUAL_TESTING.md) for a guided walkthrough of both).

No volume is mounted by default, so a removed container loses all state and a fresh one
always starts from the same pristine demo data — see [`docker/README.md`](docker/README.md)
for persistence, the environment variables the image accepts (including a self-hosted vs.
CDN switch for the web-component bundle), and how to build the image yourself.

## Repository layout

| Path | What it is |
|---|---|
| [`reconcile/`](reconcile) | The Jinks profile implementing the reconciliation server. |
| [`docker/`](docker) | The self-contained demo image: `Dockerfile`, entrypoint, config. |
| [`skills/`](skills) | An agent skill automating the profile-authoring/test/deploy loop used to build this project. |
| [`code-container/`](code-container) | A sandboxed container setup for running coding agents against this repo. |
| `README_TEST_CONTAINER.md` | Setting up a local podman/Jinks dev environment from scratch. |
| `README_MANUAL_TESTING.md` | Hands-on routines for verifying the server and client both work. |
| `README_PRESENTATION.md` | A ~20-minute talk script introducing reconciliation to a TEI/DH audience. |
| `README_PUBLISH_CONTAINER_IMAGE.md` | Steps to publish the demo image to `ghcr.io`. |

The `annotate` client patches, and other TEI Publisher components this project depends on
(`tei-publisher-jinks`, `tei-publisher-components`, `tei-publisher-lib`, `roaster`, ...), are
maintained as separate forks (see the `References` section of `AGENTS.md`) rather than
vendored into this repository.

## Conformance

The server is tested against the
[reconciliation-api JSON Schemas](https://github.com/reconciliation-api/specs) for both spec
versions on every change (via Cypress + [`cypress-ajv-schema-validator`](https://www.npmjs.com/package/cypress-ajv-schema-validator)),
and against a locally-run copy of the
[reconciliation-api test bench](https://github.com/reconciliation-api/testbench) — both the
0.2 and 1.0-draft UIs — as the final conformance gate before any change is considered done.
See `AGENTS.md` for the full development workflow.

## License

Licensed under the [GNU General Public License v3.0](LICENSE) or later.

Copyright (C) 2026 Max Planck Institute for Legal History and Legal Theory.
