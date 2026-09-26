#!/usr/bin/env node
// Pre-renders every route into a static HTML snapshot for crawlers.
//
// One-time setup:
//   cd prerender
//   npm install
// (No `playwright install` needed — this drives your existing Chrome/Edge
// install rather than downloading its own Chromium build.)
//
// Run before each deploy (or wire into CI):
//   npm run prerender
//
// Output: ../prerendered/<slug>.html  (one file per route)
// Nginx (see generate-nginx-routes.sh) serves these to known bot user agents
// only; everyone else keeps getting the normal client-rendered page.

import { chromium } from 'playwright';
import { spawn, spawnSync } from 'node:child_process';
import { readdirSync, mkdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..');
const OUT_DIR = join(REPO_ROOT, 'prerendered');
const PORT = 8091;
const BASE_URL = `http://127.0.0.1:${PORT}`;

// Shared component files — never routes on their own.
const COMPONENTS = new Set([
  'Header.dc.html',
  'Footer.dc.html',
  'BlogPost.dc.html',
  'InfoPage.dc.html',
  'ProductPage.dc.html',
]);

function slugify(name) {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

function discoverRoutes() {
  const routes = []; // { slug, filename }
  const entries = readdirSync(REPO_ROOT);

  // The home page is plain index.html (not a *.dc.html file), served at "/"
  // via Nginx's normal `index` directive — it still boots the same dc-runtime
  // though, so it still needs a snapshot.
  if (entries.includes('index.html')) {
    routes.push({ slug: '', filename: 'index.html' });
  }

  for (const filename of entries) {
    if (!filename.endsWith('.dc.html')) continue;
    if (COMPONENTS.has(filename)) continue;
    const name = filename.slice(0, -'.dc.html'.length);
    routes.push({ slug: slugify(name), filename });
  }
  return routes;
}

function resolvePythonCommand() {
  const candidates = process.platform === 'win32' ? ['python', 'py', 'python3'] : ['python3', 'python'];
  for (const cmd of candidates) {
    const args = cmd === 'py' ? ['-3', '--version'] : ['--version'];
    const result = spawnSync(cmd, args, { stdio: 'ignore' });
    if (!result.error && result.status === 0) {
      return cmd === 'py' ? { cmd, extraArgs: ['-3'] } : { cmd, extraArgs: [] };
    }
  }
  throw new Error(
    'No working Python interpreter found on PATH (tried: ' +
      candidates.join(', ') +
      '). Install Python and make sure it is on PATH.'
  );
}

async function launchBrowser() {
  // Prefer an already-installed Chrome/Edge over playwright's own Chromium
  // download, since that download is often blocked on corporate networks.
  for (const channel of ['chrome', 'msedge']) {
    try {
      const browser = await chromium.launch({ channel });
      console.log(`Using installed browser (channel: ${channel}).`);
      return browser;
    } catch {
      // try the next channel
    }
  }
  try {
    return await chromium.launch();
  } catch (e) {
    throw new Error(
      'Could not launch a browser. Install Google Chrome or Microsoft Edge, ' +
        'or run `npx playwright install chromium` on a network that can reach cdn.playwright.dev.\n' +
        `Original error: ${e.message}`
    );
  }
}

function waitForServer(url, tries = 50) {
  return new Promise((resolve, reject) => {
    const attempt = (n) => {
      fetch(url)
        .then(() => resolve())
        .catch(() => {
          if (n <= 0) return reject(new Error(`dev server never came up at ${url}`));
          setTimeout(() => attempt(n - 1), 200);
        });
    };
    attempt(tries);
  });
}

async function prerenderRoute(browser, { slug, filename }) {
  const path = slug ? `/${slug}/` : '/';
  const url = `${BASE_URL}${path}`;
  const page = await browser.newPage();
  const jsErrors = [];
  page.on('pageerror', (e) => jsErrors.push(String(e)));

  await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });

  // dc-import'd pieces (Header, Footer, nested components) fetch and render
  // async — wait until no loading placeholders remain.
  await page
    .waitForFunction(() => document.querySelectorAll('.sc-placeholder').length === 0, {
      timeout: 15000,
    })
    .catch(() => {
      console.warn(`  ! ${path}: placeholders never fully resolved (saving anyway)`);
    });

  // #dc-root having real text confirms the client render actually ran.
  await page.waitForFunction(
    () => {
      const root = document.querySelector('#dc-root');
      return !!root && root.textContent.trim().length > 0;
    },
    { timeout: 15000 }
  );

  const html = await page.evaluate(
    () => '<!DOCTYPE html>\n' + document.documentElement.outerHTML
  );
  await page.close();

  if (jsErrors.length) {
    console.warn(`  ! ${path}: ${jsErrors.length} JS error(s) during render`);
  }

  const outName = slug ? `${slug}.html` : 'home.html';
  writeFileSync(join(OUT_DIR, outName), html, 'utf8');
  console.log(`  ok ${path} -> prerendered/${outName}`);
}

async function main() {
  mkdirSync(OUT_DIR, { recursive: true });
  const routes = discoverRoutes();
  if (!routes.length) {
    console.error('No routes discovered — check COMPONENTS / HOME_FILE config.');
    process.exit(1);
  }
  console.log(`Discovered ${routes.length} route(s).`);

  const python = resolvePythonCommand();
  console.log(`Starting dev_server.py (using \`${python.cmd}\`)...`);
  const server = spawn(
    python.cmd,
    [...python.extraArgs, 'dev_server.py', '--host', '127.0.0.1', '--port', String(PORT)],
    { cwd: REPO_ROOT, stdio: 'inherit' }
  );
  let serverExited = false;
  server.on('exit', (code) => {
    serverExited = true;
    if (code !== null && code !== 0) console.error(`dev_server.py exited with code ${code}`);
  });

  try {
    await Promise.race([
      waitForServer(BASE_URL),
      new Promise((_, reject) => {
        const check = setInterval(() => {
          if (serverExited) {
            clearInterval(check);
            reject(new Error('dev_server.py exited before it started serving — see output above.'));
          }
        }, 100);
      }),
    ]);
    const browser = await launchBrowser();
    let failures = 0;
    for (const route of routes) {
      try {
        await prerenderRoute(browser, route);
      } catch (e) {
        failures++;
        console.error(`  FAIL /${route.slug}/ : ${e.message}`);
      }
    }
    await browser.close();
    console.log(`Done. ${routes.length - failures}/${routes.length} routes prerendered.`);
    if (failures) process.exitCode = 1;
  } finally {
    server.kill();
  }
}

main().catch((e) => {
  console.error(`\n${e.message}`);
  process.exit(1);
});
