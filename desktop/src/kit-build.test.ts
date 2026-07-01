// Regression tests for the Tarmac UI kit build (2607.0001_tarmac_ui_kit_design_sync_export).
//
// These read the ACTUAL files emitted by `npm run build:kit` off disk — no
// hard-coded copies of expected content — so a broken build-kit.mjs (wrong
// component list, a stray board-engine/terminal selector leaking into the kit
// stylesheet, a malformed @dsCard marker, a resurrected TitleBarChip export)
// fails these tests. Covers S1, S2, S6, S7, S13 per the spec's "For the
// Implementing Agent" section.
//
// Runs the real esbuild build once in `beforeAll` (via the project's own
// `npm run build:kit` script) so what's asserted on is exactly what a
// developer/CI would produce, not a mock.

import { describe, it, expect, beforeAll } from "vitest";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const desktopDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const distKit = path.join(desktopDir, "dist-kit");

const IN_SCOPE_COMPONENTS = [
  "CardShell",
  "DocCard",
  "BoardSwitcher",
  "ToastOverlay",
  "OffscreenHints",
  "MinimapOverlay",
  "CycleHud",
  "StatusBar",
  "ZoomControl",
  "DockPane",
] as const;

const GROUP_BY_COMPONENT: Record<(typeof IN_SCOPE_COMPONENTS)[number], "Cards" | "Overlays" | "Chrome"> = {
  CardShell: "Cards",
  DocCard: "Cards",
  BoardSwitcher: "Overlays",
  ToastOverlay: "Overlays",
  OffscreenHints: "Overlays",
  MinimapOverlay: "Overlays",
  CycleHud: "Overlays",
  StatusBar: "Chrome",
  ZoomControl: "Chrome",
  DockPane: "Chrome",
};

beforeAll(() => {
  execFileSync("node", ["scripts/build-kit.mjs"], {
    cwd: desktopDir,
    stdio: "pipe",
  });
}, 60_000);

describe("kit build output tree (S1, S13)", () => {
  it("emits tarmac-kit.js, tarmac-kit.css, and both font files", () => {
    expect(fs.existsSync(path.join(distKit, "tarmac-kit.js"))).toBe(true);
    expect(fs.existsSync(path.join(distKit, "tarmac-kit.css"))).toBe(true);
    expect(fs.existsSync(path.join(distKit, "fonts", "ibm-plex-mono-regular.woff2"))).toBe(true);
    expect(fs.existsSync(path.join(distKit, "fonts", "ibm-plex-mono-bold.woff2"))).toBe(true);
  });

  it("emits components/<name>/index.html for exactly the 10 in-scope components", () => {
    const componentsDir = path.join(distKit, "components");
    const actualDirs = fs.readdirSync(componentsDir).sort();
    expect(actualDirs).toEqual([...IN_SCOPE_COMPONENTS].sort());

    for (const name of IN_SCOPE_COMPONENTS) {
      expect(fs.existsSync(path.join(componentsDir, name, "index.html"))).toBe(true);
    }
  });

  it("does not emit a TitleBarChip directory", () => {
    expect(fs.existsSync(path.join(distKit, "components", "TitleBarChip"))).toBe(false);
  });
});

describe("window.TarmacKit surface (S2, S13)", () => {
  it("inlines React/react-dom (no bare require/external-import markers)", () => {
    const js = fs.readFileSync(path.join(distKit, "tarmac-kit.js"), "utf8");
    // A bundle that left react/react-dom external would contain a runtime
    // require()/import of the bare specifier, or esbuild's own "external" hint
    // comment. Inlining means neither appears anywhere in the output.
    expect(js).not.toMatch(/require\(\s*["']react["']\s*\)/);
    expect(js).not.toMatch(/require\(\s*["']react-dom["']\s*\)/);
    expect(js).not.toMatch(/from\s*["']react["']/);
    expect(js).not.toMatch(/from\s*["']react-dom["']/);
    expect(js).not.toMatch(/import\(\s*["']react["']\s*\)/);
    // Sanity: a real inlined chunk of react-dom/React should be sizeable.
    expect(js.length).toBeGreaterThan(50_000);
  });

  it("exposes a callable mount and a key for every in-scope component, and does not export TitleBarChip", () => {
    const js = fs.readFileSync(path.join(distKit, "tarmac-kit.js"), "utf8");
    expect(js).toContain("TarmacKit");
    expect(js).toMatch(/\bmount\b/);
    for (const name of IN_SCOPE_COMPONENTS) {
      expect(js).toContain(name);
    }
    expect(js).not.toContain("TitleBarChip");
  });
});

describe("kit stylesheet @import closure (S6)", () => {
  it("contains none of the board-engine/world/terminal selectors, and no JetBrains @font-face", () => {
    const css = fs.readFileSync(path.join(distKit, "tarmac-kit.css"), "utf8");
    expect(css).not.toContain(".term-host");
    expect(css).not.toContain(".card.docked");
    expect(css).not.toContain(".term-raster");
    expect(css).not.toContain(".term-dock-ghost");
    expect(css).not.toMatch(/\.world\b/);
    expect(css).not.toContain("JetBrains");
  });

  it("does include the shared card/chrome/token rules (sanity that the closure isn't empty)", () => {
    const css = fs.readFileSync(path.join(distKit, "tarmac-kit.css"), "utf8");
    expect(css).toContain(".card");
    expect(css).toContain("IBM Plex Mono");
    expect(css).toMatch(/src:\s*url\(\/fonts\/ibm-plex-mono-regular\.woff2\)/);
    expect(css).toMatch(/src:\s*url\(\/fonts\/ibm-plex-mono-bold\.woff2\)/);
    expect(css).toMatch(/--card-w\s*:\s*360px/);
  });
});

describe("preview HTML first-line @dsCard markers (S7)", () => {
  for (const name of IN_SCOPE_COMPONENTS) {
    it(`components/${name}/index.html starts with a well-formed @dsCard marker for group "${GROUP_BY_COMPONENT[name]}"`, () => {
      const html = fs.readFileSync(path.join(distKit, "components", name, "index.html"), "utf8");
      const firstLine = html.split("\n")[0];
      expect(firstLine).toMatch(/^<!-- @dsCard group="(Cards|Overlays|Chrome)" -->$/);
      expect(firstLine).toBe(`<!-- @dsCard group="${GROUP_BY_COMPONENT[name]}" -->`);
    });
  }
});
