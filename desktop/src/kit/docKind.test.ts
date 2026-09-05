import { describe, it, expect, vi } from "vitest";
import { docKind, cardSrcUrl } from "./docKind";

// Spec 2607.0004 — extension-only routing (S1) and card src addressing (S2).
describe("docKind (S1)", () => {
  it("html and htm route to html, case-insensitive", () => {
    expect(docKind("/a/b/a.html")).toBe("html");
    expect(docKind("/a/B.HTM")).toBe("html");
    expect(docKind("x.htm")).toBe("html");
    expect(docKind("/a/dash.HtMl")).toBe("html");
  });

  it("everything else routes to markdown", () => {
    expect(docKind("/a/a.md")).toBe("markdown");
    expect(docKind("/a/a.html.bak")).toBe("markdown");
    expect(docKind("/a/README")).toBe("markdown");
    expect(docKind("/a/a.htmlx")).toBe("markdown");
  });

  // Dotfiles and degenerate names have no extension.
  it("dotfiles and trailing dots are markdown", () => {
    expect(docKind("/a/.html")).toBe("markdown");
    expect(docKind("/a/name.")).toBe("markdown");
    expect(docKind("/a/.hidden.html")).toBe("html");
  });
});

describe("cardSrcUrl (S2)", () => {
  it("percent-encodes the whole path as one segment with ?v=mtime", () => {
    const url = cardSrcUrl("/Users/me/my dash.html", 1234);
    expect(url).toBe(
      `tarmac-card://doc/${encodeURIComponent("/Users/me/my dash.html")}?v=1234`,
    );
    // Slashes must be encoded — one segment, not a nested path.
    expect(url.slice("tarmac-card://doc/".length)).not.toContain("/");
  });

  it("encodes reserved and non-ASCII characters", () => {
    const url = cardSrcUrl("/tmp/圖表 100%#?.html", 7);
    const seg = url.slice("tarmac-card://doc/".length, url.indexOf("?v="));
    expect(decodeURIComponent(seg)).toBe("/tmp/圖表 100%#?.html");
    expect(seg).not.toContain("#");
    expect(seg).not.toContain("?");
  });

  it("missing mtime falls back to v=0", () => {
    expect(cardSrcUrl("/a.html", undefined)).toMatch(/\?v=0$/);
  });

  // Spec 2609.0001 S11 — a standing guard, not new behavior. The refresh control
  // (issue #89) re-evaluates this on every click, so purity is what keeps an
  // unchanged-mtime refresh from reloading an HTML card and losing its JS state
  // (issue #99). Fails the moment anyone reaches for Date.now()/a counter/random
  // to "make refresh actually refresh".
  //
  // The two calls must straddle a clock tick: called back-to-back they land in the
  // same millisecond, and a Date.now()-derived nonce — the first form the spec names
  // — would produce identical URLs and slip through. Fake timers make that gap
  // explicit instead of leaving the guard's reach up to how fast the machine is.
  it("is a pure function of (path, mtime) — same inputs, same URL", () => {
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date(1_700_000_000_000));
      const first = cardSrcUrl("/tmp/live.html", 1_700_000_000_000);
      vi.advanceTimersByTime(5_000);
      const second = cardSrcUrl("/tmp/live.html", 1_700_000_000_000);
      expect(second).toBe(first);
    } finally {
      vi.useRealTimers();
    }
  });
});
