# Running the reconciliation testbench (local is the default in v10)

The testbench is a client-side React app that calls your service **from the browser** and reports
pass/warn/fail per check (manifest validity, reconcile behaviour, suggest/preview/extend, CORS).
There is no server API to POST your URL to.

Decisive platform fact: TEI Publisher v10's CORS echoes the caller `Origin` only if it matches
`config:origin-whitelist`, which by default allows **only `localhost`/`127.0.0.1`**. Therefore:

- **Running the testbench locally is the default and recommended gate** — its origin
  (`http://localhost:3000`) is already whitelisted, so nothing security-relevant changes.
- The **hosted** testbench (`https://reconciliation-api.github.io`) is CORS-**blocked** unless you
  widen the whitelist; avoid unless you specifically need the canonical deployment.

Source: https://github.com/reconciliation-api/testbench

## Run it locally

```bash
git clone https://github.com/reconciliation-api/testbench.git
cd testbench && npm install
npm start          # dev server on http://localhost:3000
# or: npm run build && npx serve -s build
```

Then point it at your service root, `http://localhost:8080/exist/apps/<abbrev>/api/reconcile`, and
run the checks for the version under test. Check out / build the branch matching the spec version
when you need to distinguish 0.2 vs 1.0 behaviour. A human can eyeball the results, or automate
with the headless path below.

## Optional: drive the local testbench headlessly with Playwright

Use only if you want the testbench's verdict captured automatically (most conformance is already
covered headlessly by the Cypress + JSON-Schema layer — see cypress-testing.md). Selectors are not
specified here on purpose; the testbench DOM can change, so inspect it first
(`npx playwright codegen http://localhost:3000`) and adapt.

```bash
npm i -D playwright && npx playwright install chromium
```

```js
// run-testbench.mjs — SKELETON. Verify selectors via codegen before trusting this.
import { chromium } from 'playwright';
const TESTBENCH = process.argv[2];   // http://localhost:3000 (checked out at 0.2 or 1.0)
const ENDPOINT  = process.argv[3];   // http://localhost:8080/exist/apps/<abbrev>/api/reconcile
const OUT       = process.argv[4] ?? 'testbench-result';

const browser = await chromium.launch();
const page = await browser.newPage();
page.on('console', m => console.log('[page]', m.text())); // surfaces fetch/CORS errors
await page.goto(TESTBENCH, { waitUntil: 'networkidle' });
// TODO (from codegen): fill the endpoint field and submit, e.g.
//   await page.getByRole('textbox').first().fill(ENDPOINT);
//   await page.getByRole('button', { name: /test|submit|go/i }).click();
await page.waitForLoadState('networkidle');
await page.screenshot({ path: `${OUT}.png`, fullPage: true });
await import('fs').then(fs => fs.writeFileSync(`${OUT}.txt`, await page.evaluate(() => document.body.innerText)));
await browser.close();
```

Treat a scrape failure as "inconclusive", not "pass". A failing fetch usually appears in the page
console as a CORS/network error — that's why the console is logged. Run it for **both** 0.2 and 1.0.

## Recommended combination

- Every iteration: Cypress API tests + JSON-Schema validation + `cors-check.sh` (fast, headless).
- Before "done": the **local** testbench for **both** 0.2 and 1.0 (human-reviewed or Playwright),
  plus one run against a freshly recreated container / `jinks update --all`.
