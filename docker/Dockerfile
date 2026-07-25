# Self-contained demo image for the reconciliation project: reconcile profile + the patched
# annotate profile (dispatcher/field-mapping fixes, see the annotation_config_dispatcher_dormant
# project memory) + a self-hostable tei-publisher-components build, all baked in.
#
# The base image (existdb/teipublisher:10.0.0) has NO shell and NO coreutils - confirmed
# empirically (no /bin/sh, no cat/ls/which, java only). Every stage below that needs a real
# shell/toolchain (npm installs, rollup builds) runs in a *separate*, normal Debian-based node
# image; only static, already-built artifacts get copied into the final stage. The final
# stage's own setup (app creation, profile deployment) happens at container *first boot*, not
# at build time, via docker/entrypoint.js - a plain Node script invoked directly (exec form,
# no shebang/shell dependency anywhere). See docker/README.md for why, and for the
# PB_COMPONENTS_SOURCE runtime switch this image supports.
#
# Build (from the repo root):
#   podman build -f docker/Dockerfile -t tp-reconc-demo .
# Run:
#   podman run -d --name tp-reconc-demo -p 8080:8080 -p 8000:8000 tp-reconc-demo

# --- Stage: source of the Node.js runtime we copy into the final (shell-less) image -------
FROM node:20-slim AS nodesrc

# --- Stage: build the self-hosted tei-publisher-components bundle -------------------------
FROM node:20-slim AS components-builder
WORKDIR /src
COPY tei-publisher-components/package.json tei-publisher-components/package-lock.json ./
# `npm install` (not `ci`): the committed lockfile has drifted from package.json in this
# checkout; install is more forgiving and was confirmed working end-to-end. --ignore-scripts:
# the package's own "prepare" script (npm run docs && npm run build:production) needs
# rollup.config.js and src/, which don't exist yet at this point in the layer cache - run the
# real build explicitly below, after the full source is copied in.
RUN npm install --ignore-scripts
COPY tei-publisher-components/ ./
RUN npm run build:production

# --- Stage: install jinks-cli globally, in an environment with a real shell/npm -----------
FROM node:20-slim AS jinks-cli-builder
# Pinned to the version confirmed working throughout this project's development.
RUN npm install -g @teipublisher/jinks-cli@2.4.0 --prefix /opt/jinks-cli

# --- Final stage ----------------------------------------------------------------------------
FROM existdb/teipublisher:10.0.0

# Bring in a real Node.js runtime - copy the whole /usr/local tree (not just the `node`
# binary) so npm's own supporting files come along too. Confirmed empirically to run
# correctly against this base image's glibc (docker/README.md documents the test).
COPY --from=nodesrc /usr/local /usr/local

COPY --from=jinks-cli-builder /opt/jinks-cli /opt/jinks-cli
COPY --from=components-builder /src/dist /opt/pb-components/dist

# Profile source trees entrypoint.js deploys to the Jinks server on first boot. "annotate" is
# copied whole (not just the files this project touched) so a `jinks update` later, if ever
# run against this app, has a fully self-consistent profile source to compare against.
COPY reconcile /opt/profiles/reconcile
COPY tei-publisher-jinks/profiles/annotate /opt/profiles/annotate

COPY docker/entrypoint.js docker/app-config.json /opt/app/

EXPOSE 8080 8443

# PB_COMPONENTS_SOURCE: "self-hosted" (default) serves the components build baked into this
# image from the app's own resources/lib/ (same origin as the app itself, via base10's
# `script.webcomponents: "local"` mode - no separate port/CORS needed); "cdn" leaves it unset
# so base10's own template default (jsDelivr, a released @teipublisher/pb-components version)
# applies instead. Switch at container launch with `-e PB_COMPONENTS_SOURCE=cdn` - no rebuild
# needed, see docker/entrypoint.js's applyComponentsConfig(), which re-applies this every boot.
ENV PB_COMPONENTS_SOURCE=self-hosted \
    HTTP_PORT=8080 \
    APP_ABBREV=tp-reconc \
    ADMIN_USER=admin \
    ADMIN_PASS="" \
    APP_USER=tei \
    APP_PASS=simple

ENTRYPOINT ["/usr/local/bin/node", "/opt/app/entrypoint.js"]
