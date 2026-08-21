#!/usr/bin/env node
/**
 * scripts/ssg.mjs — static-site-generator build step for the dhake docs page.
 *
 * Pipeline:
 *
 *   1.  Expects the Elm app already compiled to `dist/elm.js`:
 *         elm make src/Main.elm --output=dist/elm.js --optimize
 *   2.  Boots a happy-dom `Window`, installs its browser globals onto
 *       globalThis (via `defineProperty`, so getter-only globals like
 *       `navigator` / `location` can be overridden), then loads the compiled
 *       Elm bundle with an *indirect eval* `(0, eval)(code)` — the bundle is a
 *       classic IIFE whose `this` binds to globalThis, so `Elm` lands on
 *       `globalThis.Elm`.
 *   3.  Creates a detached root `<div>`, calls `Elm.Main.init({ node })`, waits
 *       a couple of macrotask ticks for the initial render to flush, and reads
 *       back `node.innerHTML` — the pre-rendered docs markup, including the
 *       `<style>` node emitted by `Fixpoint.Style.stylesheet`.
 *   4.  Reads `shell/index.html` (the document skeleton: `<head>` with title +
 *       description + an empty `#app` slot), injects the rendered markup into
 *       the slot, and writes the final `dist/index.html`.
 *
 * The output page is fully static — all styling ships inline in the rendered
 * markup and there is no client-side JS, so GitHub Pages can just serve the
 * file (it uploads `dist/`).
 *
 * Run from the repo root:
 *   node scripts/ssg.mjs
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { Window } from 'happy-dom';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const DIST = join(ROOT, 'dist');
const ELM_BUNDLE = join(DIST, 'elm.js');
const SHELL_TEMPLATE = join(ROOT, 'shell', 'index.html');
const OUTPUT = join(DIST, 'index.html');

const SLOT_SELECTOR = '#app';

function log(msg) {
  console.log(`[ssg] ${msg}`);
}

/**
 * Install happy-dom's window-backed values onto globalThis so the compiled Elm
 * bundle and its runtime see a browser-shaped global object.
 *
 * `navigator` and `location` already exist on Node's globalThis as getter-only
 * properties, so they cannot be plain-assigned — `defineProperty` with
 * `configurable: true` replaces them. The remaining names either don't exist
 * in Node or are harmless to shadow, so the same call is used uniformly.
 */
function installGlobals(window) {
  const globals = [
    'window',
    'document',
    'navigator',
    'location',
    'history',
    'customElements',
    'performance',
    'requestAnimationFrame',
    'cancelAnimationFrame',
    'HTMLElement',
    'HTMLDivElement',
    'HTMLSpanElement',
    'HTMLAnchorElement',
    'HTMLButtonElement',
    'HTMLTableElement',
    'Element',
    'Node',
    'Document',
    'DocumentFragment',
    'Text',
    'Comment',
    'NodeList',
    'HTMLCollection',
    'Event',
    'CustomEvent',
    'MouseEvent',
    'KeyboardEvent',
    'UIEvent',
    'EventTarget',
    'MutationObserver',
    'getComputedStyle',
    'matchMedia',
  ];
  for (const name of globals) {
    const value = window[name];
    if (value === undefined) continue;
    Object.defineProperty(globalThis, name, {
      value,
      configurable: true,
      writable: true,
    });
  }
}

/**
 * Load the compiled Elm bundle, mount it into a fresh container and return the
 * pre-rendered HTML of the dhake docs page.
 */
async function renderPage(window) {
  const code = readFileSync(ELM_BUNDLE, 'utf8');
  // eslint-disable-next-line no-eval -- indirect eval runs in global scope, so
  // the bundle's IIFE `(this)` binds to globalThis and defines globalThis.Elm.
  (0, eval)(code);

  const Elm = globalThis.Elm;
  if (!Elm || !Elm.Main || typeof Elm.Main.init !== 'function') {
    throw new Error('dist/elm.js did not expose Elm.Main.init on globalThis');
  }

  const root = window.document.createElement('div');
  root.setAttribute('id', 'docs-root');
  window.document.body.appendChild(root);

  Elm.Main.init({ node: root });

  // Let Elm's initial render flush. Browser.element schedules its first paint
  // through the virtual DOM, which Elm drives with requestAnimationFrame /
  // macrotasks. Flushing happy-dom's async task manager covers both; fall back
  // to a couple of macrotask ticks for robustness on any happy-dom version.
  const flush = window.happyDOM && typeof window.happyDOM.whenAsyncComplete === 'function'
    ? () => window.happyDOM.whenAsyncComplete()
    : () => new Promise((resolve) => setTimeout(resolve, 0));
  await flush();
  await flush();

  return root.innerHTML;
}

/**
 * Inject the pre-rendered docs markup into the shell template's `#app` slot
 * and return the final, complete HTML document.
 */
function injectRendered(shellHtml, rendered) {
  const win = new Window();
  const doc = win.document;
  doc.write(shellHtml);
  doc.close();

  const slot = doc.querySelector(SLOT_SELECTOR);
  if (!slot) {
    throw new Error(
      `shell/index.html has no ${SLOT_SELECTOR} element to inject the rendered page into`,
    );
  }
  slot.innerHTML = rendered;

  return `<!DOCTYPE html>\n${doc.documentElement.outerHTML}\n`;
}

async function main() {
  if (!existsSync(ELM_BUNDLE)) {
    console.error(
      `[ssg] missing ${ELM_BUNDLE}. Build it first:\n` +
        '  elm make src/Main.elm --output=dist/elm.js --optimize',
    );
    process.exit(1);
  }

  const window = new Window();
  installGlobals(window);

  log('rendering dhake Elm page under happy-dom …');
  const rendered = await renderPage(window);
  log(`rendered ${rendered.length} bytes of docs markup`);

  const shellHtml = readFileSync(SHELL_TEMPLATE, 'utf8');
  const finalHtml = injectRendered(shellHtml, rendered);

  mkdirSync(DIST, { recursive: true });
  writeFileSync(OUTPUT, finalHtml);
  log(`wrote ${OUTPUT} (${finalHtml.length} bytes)`);
}

main().catch((err) => {
  console.error('[ssg] failed:', err);
  process.exit(1);
});
