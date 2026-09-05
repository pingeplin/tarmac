// Regression tests for the shipped QA artifact `desktop/qa/cull-probe.html`
// (spec 2609.0002 S37).
//
// The probe is not application code, so nothing else in the suite would notice
// if it stopped running — and that is exactly what happened once: a literal
// `</script>` inside a `//` comment ended the first script element, so the
// outstanding-count IIFE never ran, `TM` was undefined, the reporter threw a
// ReferenceError, and the counters read "–" forever. The card looked alive and
// measured nothing. It cost a full QA cycle to find.
//
// These read the file off disk and actually EXECUTE it in a `node:vm` against
// fake schedulers, then assert a real report line comes out. Same shipped-artifact
// principle as kit-build.test.ts and card-shim.test.ts.

import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const PROBE_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "qa",
  "cull-probe.html",
);
const HTML = fs.readFileSync(PROBE_PATH, "utf8");

/** Split exactly as an HTML parser would: a script element ends at the first
 *  literal `</script`, wherever it appears — comment or string included. */
function parseScripts(html: string): string[] {
  const out: string[] = [];
  const open = /<script(?:\s[^>]*)?>/gi;
  let m: RegExpExecArray | null;
  while ((m = open.exec(html)) !== null) {
    const start = m.index + m[0].length;
    const end = html.slice(start).search(/<\/script/i);
    out.push(html.slice(start, end === -1 ? undefined : start + end));
    if (end !== -1) open.lastIndex = start + end;
  }
  return out;
}

describe("cull-probe.html is a well-formed, runnable document (S37)", () => {
  it("declares its switches in a cull-probe meta tag", () => {
    // A card is opened by path, and cardSrcUrl serves it as
    // tarmac-card://doc/<encoded path>?v=<mtime> — so location.search always
    // belongs to the host and can never carry the tester's switches. That the
    // meta tag is what the script actually reads is proven by the end-to-end
    // case below, whose fake location.search deliberately carries none of them.
    expect(HTML).toMatch(/<meta\s+name="cull-probe"\s+content="[^"]*"/);
    for (const src of parseScripts(HTML)) {
      expect(src.replace(/\/\/[^\n]*/g, "")).not.toMatch(/location\s*\.\s*search/);
    }
  });

  it("closes exactly as many script elements as it opens", () => {
    // The exact defect that silently disabled the probe: a literal `</script>`
    // in a `//` comment ends the element early, so the file grows a third
    // closer and the rest of the block renders as body text. It must be spelled
    // `<\/script>`. Counting closers is the assertion with teeth here — checking
    // the parsed bodies is not, since the parser has already truncated at it.
    expect((HTML.match(/<\/script/gi) ?? []).length).toBe(2);
  });

  it("both script blocks are syntactically complete", () => {
    const scripts = parseScripts(HTML);
    expect(scripts.length).toBe(2);
    for (const src of scripts) expect(() => new Function(src)).not.toThrow();
  });

  it("runs end to end and emits a [cull] report line carrying the gaps", () => {
    const logs: string[] = [];
    const intervals: Array<{ cb: () => void; delay: number }> = [];
    const meta = { content: "n=4 loops=all across=9000 ms=1000" };
    const els: Record<string, { textContent: string }> = {};

    const win: any = {
      console: { log: (...a: unknown[]) => logs.push(a.join(" ")) },
      location: { search: "?v=123", pathname: "/doc/whatever" },
      requestAnimationFrame: () => 1,
      cancelAnimationFrame: () => {},
      setTimeout: () => 2,
      clearTimeout: () => {},
      setInterval: (cb: () => void, delay: number) => intervals.push({ cb, delay }),
      clearInterval: () => {},
      document: {
        querySelector: (sel: string) =>
          sel.includes("cull-probe") ? meta : sel.includes("tarmac-zoom") ? null : null,
        getElementById: (id: string) => (els[id] ??= { textContent: "" }),
      },
    };
    win.window = win;
    vm.createContext(win);
    for (const src of parseScripts(HTML)) {
      vm.runInContext(src, win, { filename: "cull-probe.html" });
    }

    // The boot line proves the second block ran to completion — i.e. `TM` from
    // the first block existed. That is the assertion the original defect fails.
    expect(logs.some((l) => l.startsWith("[cull] boot="))).toBe(true);

    // Drive the reporter (the last interval registered) and read its line.
    expect(intervals.length).toBeGreaterThan(0);
    intervals[intervals.length - 1].cb();

    const report = logs.find((l) => l.includes(" dt="));
    expect(report).toBeDefined();
    for (const field of ["gapRaf=", "gapInt=", "gapTo=", "outstanding=", "across="]) {
      expect(report).toContain(field);
    }
    // The meta tag's values reached the script.
    expect(report).toContain("n=4");
    expect(report).toContain("loops=all");
  });
});
