#!/usr/local/bin/node
// entrypoint.js — container entrypoint for the reconciliation demo image.
//
// The base image (existdb/teipublisher:10.0.0) has no shell and no coreutils (confirmed
// empirically: no /bin/sh, no cat/ls/which) — it is Java + eXist only. Everything this
// container needs beyond that (jinks-cli, this orchestration) is supplied by copying a real
// Node.js binary in at build time (see ../Dockerfile) and never relying on shell/env
// resolution anywhere - every subprocess is spawned as `node <script.js> ...` directly, not
// via a shebang.
//
// On first boot (detected by asking the app's own manifest route whether it exists yet):
//   1. upload the reconcile profile source tree to the Jinks server's own profile registry
//   2. upload the (already-patched-in-the-image) annotate profile source tree the same way
//      - this is what keeps the annotate profile's dispatcher/field-mapping fixes in effect
//        even though they live in a profile TEI Publisher's own base image also bundles;
//        see the annotation_config_dispatcher_dormant project memory for why this specific
//        profile needed re-deploying at all
//   3. create the tp-reconc app via jinks-cli
// On every boot (first or not):
//   - upload the pre-built tei-publisher-components dist/ (see ../Dockerfile's
//     components-builder stage) into the app's own resources/lib/ collection, and
//   - apply the config.json script block $PB_COMPONENTS_SOURCE wants
// so restarting the container with a different source, or a rebuilt image with newer
// components, takes effect without a full re-init.
//
// Then it waits on the eXist child process, forwarding SIGTERM/SIGINT to it for a clean
// shutdown.

import { spawn } from 'node:child_process';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';

const HERE = path.dirname(fileURLToPath(import.meta.url));

const HTTP_PORT = process.env.HTTP_PORT || '8080';
// 'self-hosted' (default): serve tei-publisher-components from the app's own resources/lib/
// (same origin, no CORS, no separate port) via base10's `script.webcomponents: "local"` mode.
// 'cdn': leave config.json's `script` block unset so base10's own template default applies
// (jsDelivr, a released @teipublisher/pb-components version) - see docker/README.md.
const PB_COMPONENTS_SOURCE = process.env.PB_COMPONENTS_SOURCE || 'self-hosted';
const APP_ABBREV = process.env.APP_ABBREV || 'tp-reconc';
const ADMIN_USER = process.env.ADMIN_USER || 'admin';
const ADMIN_PASS = process.env.ADMIN_PASS || '';
const APP_USER = process.env.APP_USER || 'tei';
const APP_PASS = process.env.APP_PASS || 'simple';

const BASE = `http://localhost:${HTTP_PORT}`;
const JINKS_SERVER = `${BASE}/exist/apps/jinks`;
const NODE_BIN = process.execPath; // the copied node binary itself, never rely on PATH/env
// `npm install -g --prefix /opt/jinks-cli ...` (see ../Dockerfile) places the package under
// lib/node_modules/, the same layout as any global npm install with a custom prefix.
const JINKS_CLI_ENTRY = '/opt/jinks-cli/lib/node_modules/@teipublisher/jinks-cli/index.js';

function log(...args) {
  console.log('[entrypoint]', ...args);
}

function basicAuthHeader(user, pass) {
  return `Basic ${Buffer.from(`${user}:${pass}`).toString('base64')}`;
}

async function waitReady(timeoutMs = 180000) {
  const url = `${JINKS_SERVER}/`;
  const deadline = Date.now() + timeoutMs;
  log(`waiting for ${url} ...`);
  for (;;) {
    try {
      const res = await fetch(url);
      if (res.status === 200) {
        log('eXist is ready.');
        return;
      }
    } catch {
      // connection refused while Jetty is still starting - expected, keep polling
    }
    if (Date.now() > deadline) {
      throw new Error(`Timed out waiting for ${url}`);
    }
    await new Promise(r => setTimeout(r, 3000));
  }
}

async function isAppInitialized() {
  try {
    const res = await fetch(`${BASE}/exist/apps/${APP_ABBREV}/api/reconcile`);
    return res.status === 200;
  } catch {
    return false;
  }
}

async function runXQuery(query) {
  const envelope = `<query xmlns="http://exist.sourceforge.net/NS/exist" wrap="no"><text><![CDATA[${query}]]></text></query>`;
  const res = await fetch(`${BASE}/exist/rest/db`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/xml',
      Authorization: basicAuthHeader(ADMIN_USER, ADMIN_PASS),
    },
    body: envelope,
  });
  const text = await res.text();
  if (!res.ok || text.includes('<exception>')) {
    throw new Error(`XQuery failed (HTTP ${res.status}): ${text.slice(0, 500)}`);
  }
  return text;
}

const CONTENT_TYPES = {
  '.json': 'application/json',
  '.xql': 'application/xquery',
  '.xqm': 'application/xquery',
  '.xml': 'application/xml',
  '.js': 'application/javascript',
  '.mjs': 'application/javascript',
  '.html': 'text/html',
  '.css': 'text/css',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
};

async function walk(dir, base = dir, out = [], skip = new Set(['doc', 'node_modules', '.git'])) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (entry.isDirectory() && skip.has(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await walk(full, base, out, skip);
    } else {
      out.push(path.relative(base, full));
    }
  }
  return out;
}

// Idempotently create every collection in `target`'s path plus every directory under
// `localDir` needed to hold `files` (relative paths), then PUT each file with a
// Content-Type matched to its extension. Mirrors
// skills/teipublisher-reconciliation-testing/scripts/ci-bootstrap-profile.sh, generalized
// for any target collection (profile registration, or an app's own resources/).
// A Content-Type of text/html (or other XML-ish types) makes eXist's REST PUT attempt to
// parse the body as well-formed XML before storing it - confirmed empirically: a stray
// unescaped "&" in dist/api.html's inline CSS (`@import url('...&display=swap')`, completely
// normal, valid HTML/CSS, just not valid XML) makes the PUT fail with a bare 400 and no body.
// Third-party build output (tei-publisher-components' dist/) can't be assumed XML-well-formed,
// so its .html files are uploaded as application/octet-stream instead - safe there, since
// nothing under resources/lib/ needs its .html served with a specific MIME type (the actual
// component loading only touches .js files, which keep their real Content-Type). This must
// NOT apply to the reconcile/annotate profile trees: their .html page templates are read back
// by Jinks' own templating engine as XML (doc()), not served as static files, and need to
// stay stored as proper XML resources.
function contentTypeFor(rel, { htmlAsBinary = false } = {}) {
  const ext = path.extname(rel);
  if (ext === '.html' && htmlAsBinary) return 'application/octet-stream';
  return CONTENT_TYPES[ext] || 'application/octet-stream';
}

async function deployTree(localDir, files, target, opts = {}) {
  const dirs = new Set();
  for (const rel of files) {
    let d = path.dirname(rel);
    while (d && d !== '.') {
      dirs.add(d);
      d = path.dirname(d);
    }
  }
  const dirList = [target, ...[...dirs].map(d => `${target}/${d}`)];

  const mkcolFn = `
    declare function local:mkcol($path as xs:string) {
        if (xmldb:collection-available($path)) then ()
        else
            let $parent := substring-before($path, "/" || tokenize($path, "/")[last()])
            let $name := tokenize($path, "/")[last()]
            return (
                if ($parent = "" or xmldb:collection-available($parent)) then () else local:mkcol($parent),
                xmldb:create-collection($parent, $name),
                sm:chown(xs:anyURI($path), "${APP_USER}"),
                sm:chgrp(xs:anyURI($path), "${APP_USER}"),
                sm:chmod($path, "rwxrwxr-x")
            )
    };
    for $d in (${dirList.map(d => `"${d}"`).join(', ')}) return local:mkcol($d)
  `;
  await runXQuery(mkcolFn);

  for (const rel of files) {
    const localPath = path.join(localDir, rel);
    const ct = contentTypeFor(rel, opts);
    const body = await readFile(localPath);
    const res = await fetch(`${BASE}/exist/rest${target}/${rel}`, {
      method: 'PUT',
      headers: {
        'Content-Type': ct,
        Authorization: basicAuthHeader(ADMIN_USER, ADMIN_PASS),
      },
      body,
    });
    if (![200, 201].includes(res.status)) {
      throw new Error(`Failed to upload ${rel} to ${target}: HTTP ${res.status}`);
    }
  }
  log(`deployed ${files.length} files to ${target}`);
}

async function deployProfileTree(localDir, profileName) {
  const files = await walk(localDir);
  await deployTree(localDir, files, `/db/apps/jinks/profiles/${profileName}`);
}

// Uploads the pre-built tei-publisher-components dist/ into the app's own resources/lib/ -
// what base10's `script.webcomponents: "local"` mode expects (see base.html's
// `[% elif $script?webcomponents = 'local' %]` branch, which serves from exactly this path,
// same origin as the app itself - no separate server/port/CORS needed). Run on every boot,
// not just first boot, so a rebuilt image's newer components reach an app on a persisted
// volume without a full re-init.
async function deployComponents() {
  const localDir = '/opt/pb-components/dist';
  const files = await walk(localDir, localDir, [], new Set(['node_modules', '.git']));
  await deployTree(localDir, files, `/db/apps/${APP_ABBREV}/resources/lib`, { htmlAsBinary: true });

  // pb-page.js's i18next backend loads translations from `resources/i18n/{{ns}}/{{lng}}.json`,
  // resolved relative to wherever the component script itself was loaded from - i.e.
  // `resources/i18n/`, a sibling of `resources/lib/` above, NOT bundled inside dist/. Confirmed
  // missing empirically: without this, generic UI strings (search.placeholder, login.user,
  // browse.items, facets.*, ...) rendered as their raw i18next keys instead of translated text.
  const i18nDir = '/opt/pb-components/i18n';
  const i18nFiles = await walk(i18nDir, i18nDir, [], new Set(['node_modules', '.git']));
  await deployTree(i18nDir, i18nFiles, `/db/apps/${APP_ABBREV}/resources/i18n`);
}

function spawnNode(args, opts = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(NODE_BIN, args, { stdio: 'inherit', ...opts });
    child.on('exit', code => {
      if (code === 0) resolve();
      else reject(new Error(`${args.join(' ')} exited with code ${code}`));
    });
    child.on('error', reject);
  });
}

function jinksCliCommonArgs() {
  return ['-s', JINKS_SERVER, '-u', APP_USER, '-p', APP_PASS, '-q'];
}

async function createApp() {
  // app-config.json's pkg.abbrev must match $APP_ABBREV (jinks create <abbrev> and the
  // config file's own pkg.abbrev both feed into the same app identity) - rewrite it into a
  // temp file rather than assuming the baked-in template's default ("tp-reconc") is what
  // was actually requested.
  const template = JSON.parse(await readFile(path.join(HERE, 'app-config.json'), 'utf8'));
  template.pkg = { ...(template.pkg || {}), abbrev: APP_ABBREV };
  const configPath = path.join(os.tmpdir(), 'app-config.json');
  await writeFile(configPath, JSON.stringify(template, null, 2));

  await spawnNode([JINKS_CLI_ENTRY, 'create', APP_ABBREV, '-c', configPath, ...jinksCliCommonArgs()]);
  log(`created app "${APP_ABBREV}"`);
}

// Applied on every boot, not just first boot, so restarting the container with a different
// $PB_COMPONENTS_SOURCE takes effect without a full re-init.
//
// Two steps, both required: PUTting config.json alone is NOT enough - confirmed empirically.
// base.html's `[% if $script?webcomponents = ... %]` branches read from
// modules/generated-config.xql, a file *generated at app-creation/update time* from
// base10/modules/generated-config.tpl.xqm - it does not re-read config.json live per request.
// `jinks update` (no -c needed - it diffs the app's own already-stored config.json against
// what it last generated from) is what actually regenerates that module; skipping it leaves
// the raw config.json changed but every already-compiled page still serving the old value.
async function applyComponentsConfig() {
  const current = await fetch(`${BASE}/exist/rest/db/apps/${APP_ABBREV}/config.json`, {
    headers: { Authorization: basicAuthHeader(ADMIN_USER, ADMIN_PASS) },
  }).then(r => r.json());

  if (PB_COMPONENTS_SOURCE === 'self-hosted') {
    current.script = { webcomponents: 'local' };
  } else {
    // 'cdn': drop any override so base10's own template default (jsDelivr, a released
    // @teipublisher/pb-components version) applies - the same thing every other,
    // non-self-hosted TEI Publisher app does.
    delete current.script;
  }

  const res = await fetch(`${BASE}/exist/rest/db/apps/${APP_ABBREV}/config.json`, {
    method: 'PUT',
    headers: {
      'Content-Type': 'application/json',
      Authorization: basicAuthHeader(ADMIN_USER, ADMIN_PASS),
    },
    body: JSON.stringify(current, null, 2),
  });
  if (![200, 201].includes(res.status)) {
    throw new Error(`Failed to apply config.json: HTTP ${res.status}`);
  }

  await spawnNode([JINKS_CLI_ENTRY, 'update', APP_ABBREV, ...jinksCliCommonArgs()]);
  log(`applied script.webcomponents for PB_COMPONENTS_SOURCE=${PB_COMPONENTS_SOURCE}`);
}

async function main() {
  // 'java' resolves via PATH (Node's spawn() does its own PATH lookup, no shell needed) -
  // the base image's own default Entrypoint already relies on the same resolution.
  const exist = spawn('java', ['org.exist.start.Main', 'jetty'], {
    stdio: 'inherit',
  });
  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => exist.kill(sig));
  }
  exist.on('exit', code => process.exit(code ?? 0));

  await waitReady();

  if (!(await isAppInitialized())) {
    log(`"${APP_ABBREV}" not found - running first-boot setup...`);
    await deployProfileTree('/opt/profiles/reconcile', 'reconcile');
    await deployProfileTree('/opt/profiles/annotate', 'annotate');
    // Patched stock profile (see ../Dockerfile's COPY comment): fixes a missing
    // features.forms.enabled flag that otherwise silently disables fore.js/fore.css loading.
    await deployProfileTree('/opt/profiles/forms', 'forms');
    await createApp();
    // Safety net for the patched tei-publisher-lib .xar (see ../Dockerfile's autodeploy
    // COPY): autodeploy installs it before Jetty accepts requests, so a fresh app's ODDs
    // should already compile against the fixed library - but explicitly recompiling here
    // matches the exact, proven-working procedure (see README_TEST_CONTAINER.md) rather
    // than relying on that timing assumption alone.
    //
    // /api/odd is gated by x-constraints (roaster's auth.xql: authenticated-but-not-yet-
    // authorized reads as a plain 401 "Access denied", same shape as a bad password) checked
    // against the app-user's group membership - immediately after `jinks create` returns,
    // that membership hasn't always propagated yet (confirmed empirically: the identical
    // request, retried a few seconds later by hand, succeeds). Retry instead of trusting the
    // first attempt.
    let recompileStatus;
    for (let attempt = 1; attempt <= 5; attempt++) {
      const recompile = await fetch(`${BASE}/exist/apps/${APP_ABBREV}/api/odd`, {
        method: 'POST',
        headers: { Authorization: basicAuthHeader(APP_USER, APP_PASS) },
      });
      recompileStatus = recompile.status;
      if (recompileStatus === 200) break;
      log(`recompile ODDs attempt ${attempt}: HTTP ${recompileStatus} - retrying...`);
      await new Promise(resolve => setTimeout(resolve, attempt * 1000));
    }
    log(`recompiled ODDs: HTTP ${recompileStatus}`);
  } else {
    log(`"${APP_ABBREV}" already exists - skipping first-boot setup.`);
  }

  await deployComponents();
  await applyComponentsConfig();
  log('Ready:');
  log(`  App:        ${BASE}/exist/apps/${APP_ABBREV}`);
  log(`  Reconcile:  ${BASE}/exist/apps/${APP_ABBREV}/api/reconcile`);
}

main().catch(err => {
  console.error('[entrypoint] FATAL:', err);
  process.exit(1);
});
