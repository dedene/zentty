// Generates src/components/xterm/xtermHtml.generated.ts — a single self-contained
// HTML document with xterm.js, its CSS, and the fit addon all INLINED, so the
// WebView terminal loads with zero network access (the app is offline-capable).
//
// xterm runs only inside the WebView, never in the RN/Hermes bundle, so the
// `@xterm/*` packages are build-time-only devDependencies: this script reads
// their shipped UMD/CSS from node_modules and bakes them into a string constant.
//
// Re-run after bumping @xterm/xterm or @xterm/addon-fit:
//   node scripts/build-xterm-html.mjs
//
// The output is committed (not built at RN bundle time) so `pnpm test`/`typecheck`
// and Metro never need the xterm packages present.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const req = (p) => readFileSync(resolve(root, p), 'utf8');

const xtermJs = req('node_modules/@xterm/xterm/lib/xterm.js');
const xtermCss = req('node_modules/@xterm/xterm/css/xterm.css');
const fitJs = req('node_modules/@xterm/addon-fit/lib/addon-fit.js');

if (/<\/script>/i.test(xtermJs) || /<\/script>/i.test(fitJs)) {
  throw new Error('xterm bundle contains a literal </script> — inlining would break the HTML');
}

// The bridge glue. `window.__zentty` is the RN → WebView surface (driven via
// injectJavaScript); postMessage is the WebView → RN surface (ready + resize).
const bridge = `
(function () {
  var term = null;
  var fit = null;
  // Non-null while the MAC owns the grid: the emulator is pinned to the mac's
  // snapshot geometry and CSS-scaled (letterboxed) into whatever room the phone
  // has. Cleared once the phone holds a control lease, which is the only state
  // where the mac follows the phone's size and the fit addon may run.
  var fixed = null;

  function post(msg) {
    if (window.ReactNativeWebView) {
      window.ReactNativeWebView.postMessage(JSON.stringify(msg));
    }
  }

  // Standard base64 (RFC 4648 §4, with padding) -> bytes. The mac encodes raw PTY
  // output this way; xterm.write accepts a Uint8Array and does its own UTF-8 decode.
  function b64ToBytes(b64) {
    var bin = atob(b64);
    var len = bin.length;
    var out = new Uint8Array(len);
    for (var i = 0; i < len; i++) { out[i] = bin.charCodeAt(i); }
    return out;
  }

  // CSS cell metrics, so the pinned grid's natural pixel size can be computed.
  function cellSize() {
    try {
      var d = term._core._renderService.dimensions.css.cell;
      if (d && d.width > 0 && d.height > 0) { return d; }
    } catch (e) {}
    return null;
  }

  // Letterbox: scale the fixed grid to fit the available box and centre it.
  // Never scale up past 1 — magnified cells look worse than empty margins.
  function applyLetterbox() {
    var el = term && term.element;
    var host = document.getElementById('root');
    if (!el || !host) { return; }
    if (!fixed) {
      el.style.transform = '';
      el.style.transformOrigin = '';
      el.style.width = '';
      el.style.height = '';
      return;
    }
    var cell = cellSize();
    if (!cell) { return; }
    var natW = cell.width * fixed.cols;
    var natH = cell.height * fixed.rows;
    var pad = 16; // #root padding, both sides
    var availW = Math.max(host.clientWidth - pad, 1);
    var availH = Math.max(host.clientHeight - pad, 1);
    var scale = Math.min(availW / natW, availH / natH, 1);
    el.style.width = natW + 'px';
    el.style.height = natH + 'px';
    el.style.transformOrigin = 'top left';
    el.style.transform =
      'translate(' + ((availW - natW * scale) / 2) + 'px,' +
      ((availH - natH * scale) / 2) + 'px) scale(' + scale + ')';
  }

  function doFit() {
    if (!term) { return; }
    if (fixed) {
      // Mac-authoritative: the phone must not renegotiate the grid, only rescale.
      applyLetterbox();
      return;
    }
    if (!fit) { return; }
    try { fit.fit(); } catch (e) {}
    post({ type: 'resize', cols: term.cols, rows: term.rows });
  }

  window.__zentty = {
    writeBatch: function (arr) {
      if (!term) { return; }
      for (var i = 0; i < arr.length; i++) { term.write(b64ToBytes(arr[i])); }
    },
    reset: function () { if (term) { term.reset(); } },
    fit: doFit,
    // Pin the emulator to the mac's snapshot grid and letterbox it.
    setGrid: function (cols, rows) {
      if (!term) { return; }
      fixed = { cols: cols, rows: rows };
      try { term.resize(cols, rows); } catch (e) {}
      applyLetterbox();
    },
    // Hand the grid back to the phone (control lease held): un-pin and refit.
    releaseGrid: function () {
      if (!term) { return; }
      fixed = null;
      applyLetterbox();
      doFit();
    },
    setTheme: function (theme) { if (term) { term.options.theme = theme; } }
  };

  function boot(theme, fontSize, scrollback) {
    term = new Terminal({
      fontSize: fontSize,
      fontFamily: 'Menlo, Monaco, "SF Mono", "Courier New", monospace',
      lineHeight: 1.2,
      scrollback: scrollback,
      cursorBlink: false,
      disableStdin: true,          // display-only: native InputBar owns input
      convertEol: false,
      allowProposedApi: true,
      theme: theme
    });
    fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open(document.getElementById('root'));

    // Keep the hidden textarea from ever grabbing focus / raising the keyboard,
    // but leave touch scrolling and text selection on the rendered rows intact.
    var ta = document.querySelector('.xterm-helper-textarea');
    if (ta) { ta.setAttribute('readonly', 'readonly'); ta.setAttribute('inputmode', 'none'); ta.tabIndex = -1; }

    window.addEventListener('resize', doFit);
    requestAnimationFrame(function () { doFit(); post({ type: 'ready' }); });
  }

  // The RN side calls window.__zenttyBoot(...) once with the resolved theme so the
  // colors come from the app's design tokens rather than being frozen in this asset.
  window.__zenttyBoot = boot;
  post({ type: 'loaded' });
})();
`;

const html = `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover" />
<style>${xtermCss}</style>
<style>
  html, body { margin: 0; padding: 0; height: 100%; background: #05070A; overflow: hidden; }
  #root { position: absolute; inset: 0; padding: 8px; box-sizing: border-box; }
  .xterm { height: 100%; }
  .xterm-viewport { -webkit-overflow-scrolling: touch; }
  ::-webkit-scrollbar { width: 6px; height: 6px; }
  ::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.18); border-radius: 3px; }
</style>
<script>${xtermJs}</script>
<script>${fitJs}</script>
</head>
<body>
<div id="root"></div>
<script>${bridge}</script>
</body>
</html>`;

const outDir = resolve(root, 'src/components/xterm');
mkdirSync(outDir, { recursive: true });
const outFile = resolve(outDir, 'xtermHtml.generated.ts');
const banner =
  '// AUTO-GENERATED by scripts/build-xterm-html.mjs — do not edit by hand.\n' +
  '// Re-run `node scripts/build-xterm-html.mjs` after bumping @xterm/* deps.\n' +
  '/* eslint-disable */\n';
writeFileSync(outFile, banner + 'export const XTERM_HTML = ' + JSON.stringify(html) + ';\n');
console.log('wrote', outFile, `(${(html.length / 1024).toFixed(0)} KiB html)`);
