// Standalone build script for the Tarmac UI kit (decision (a) of
// 2607.0001_tarmac_ui_kit_design_sync_export). Uses esbuild's JS API directly —
// NOT Vite — so this never touches `tsc && vite build` / `desktop/dist/`. Emits
// desktop/dist-kit/: a single IIFE (window.TarmacKit, React/react-dom/marked
// inlined), the compiled kit stylesheet, the vendored fonts, and one
// @dsCard-marked preview HTML per in-scope component.
//
// Wired to `npm run build:kit` and the root Makefile's `.PHONY: kit` target.
// Deliberately never invoked by `make app` / `make core` (see S12 of the spec).

import * as esbuild from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";
import { fixtures } from "./kit-fixtures.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const desktopDir = path.resolve(__dirname, "..");
const srcDir = path.join(desktopDir, "src");
const distKit = path.join(desktopDir, "dist-kit");

// Reasonable modern-browser baseline for a WKWebView-hosted (Tauri) target.
const BROWSER_TARGET = ["chrome100", "safari15", "firefox100"];

function clean() {
  fs.rmSync(distKit, { recursive: true, force: true });
  fs.mkdirSync(distKit, { recursive: true });
}

async function buildJs() {
  await esbuild.build({
    entryPoints: [path.join(srcDir, "kit-entry.ts")],
    outfile: path.join(distKit, "tarmac-kit.js"),
    bundle: true,
    format: "iife",
    globalName: "TarmacKit",
    minify: false,
    target: BROWSER_TARGET,
    // Matches tsconfig.json's "jsx": "react-jsx" (React 19 automatic transform).
    jsx: "automatic",
    // react-dom checks process.env.NODE_ENV; there is no `process` global in a
    // bare browser page, so this must be statically defined away.
    define: { "process.env.NODE_ENV": JSON.stringify("production") },
    logLevel: "info",
  });
}

async function buildCss() {
  await esbuild.build({
    entryPoints: [path.join(srcDir, "theme", "kit.css")],
    outfile: path.join(distKit, "tarmac-kit.css"),
    bundle: true,
    minify: false,
    // The @font-face `src: url('/fonts/...')` rules use absolute paths that are
    // copied into place by copyFonts() below — leave them untouched rather than
    // letting esbuild try (and fail) to resolve them as filesystem paths.
    external: ["/fonts/*"],
    logLevel: "info",
  });
}

function copyFonts() {
  const fontsOut = path.join(distKit, "fonts");
  fs.mkdirSync(fontsOut, { recursive: true });
  for (const name of ["ibm-plex-mono-regular.woff2", "ibm-plex-mono-bold.woff2"]) {
    fs.copyFileSync(path.join(desktopDir, "public", "fonts", name), path.join(fontsOut, name));
  }
}

/** Renders one components/<name>/index.html. First line MUST be exactly the
 * @dsCard marker (no leading blank line/whitespace) — this is the fixed
 * DesignSync contract the app's self-check compiles _ds_manifest.json from. */
function renderPreviewHtml(name, fixture) {
  const mountHtml = fixture.wrapInBoard
    ? '<div class="board"><div id="mount"></div></div>'
    : '<div id="mount"></div>';
  const fnLines = Object.entries(fixture.fns ?? {})
    .map(([key, src]) => `      props[${JSON.stringify(key)}] = ${src};`)
    .join("\n");
  const propsJson = JSON.stringify(fixture.props, null, 2);

  return `<!-- @dsCard group="${fixture.group}" -->
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>${name} — Tarmac UI Kit</title>
  <link rel="stylesheet" href="../../tarmac-kit.css" />
</head>
<body>
  ${mountHtml}
  <script src="../../tarmac-kit.js"></script>
  <script>
    (function () {
      var props = ${propsJson};
${fnLines}
      TarmacKit.mount(${JSON.stringify(name)}, props, document.getElementById("mount"));
    })();
  </script>
</body>
</html>
`;
}

function writePreviews() {
  for (const [name, fixture] of Object.entries(fixtures)) {
    const dir = path.join(distKit, "components", name);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "index.html"), renderPreviewHtml(name, fixture));
  }
}

async function main() {
  clean();
  await buildJs();
  await buildCss();
  copyFonts();
  writePreviews();
  console.log(`\nTarmac UI kit built -> ${path.relative(desktopDir, distKit)}/`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
