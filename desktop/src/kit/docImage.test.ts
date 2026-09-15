import { describe, it, expect, vi } from "vitest";
import { localImagePath, docImageSrc } from "./docImage";

// Spec 2609.0014 — doc-card <img src> resolution (S1–S9) and addressing (S10–S11).
const DOC = "/r/README.md";

describe("localImagePath — relative src", () => {
  it("S1: joins onto the doc's directory with dot segments normalized", () => {
    expect(localImagePath("docs/images/logo.png", DOC)).toBe("/r/docs/images/logo.png");
    expect(localImagePath("./x.png", DOC)).toBe("/r/x.png");
    expect(localImagePath("../x.png", DOC)).toBe("/x.png");
    expect(localImagePath("a/./b/../c.png", DOC)).toBe("/r/a/c.png");
    expect(localImagePath("./x:y.png", DOC)).toBe("/r/x:y.png");
  });
});

describe("localImagePath — absolute src", () => {
  it("S2: keeps an absolute path, normalized", () => {
    expect(localImagePath("/abs/dir/x.png", DOC)).toBe("/abs/dir/x.png");
    expect(localImagePath("/abs/../x.png", DOC)).toBe("/x.png");
  });
});

describe("localImagePath — file:// URLs", () => {
  it("S3: a local file:// URL's path goes through the same steps", () => {
    expect(localImagePath("file:///abs/x.png", DOC)).toBe("/abs/x.png");
    expect(localImagePath("file://localhost/abs/x.png", DOC)).toBe("/abs/x.png");
    expect(localImagePath("FILE:///abs/x.png", DOC)).toBe("/abs/x.png");
    expect(localImagePath("file:///abs/my%20pic.png#x", DOC)).toBe("/abs/my pic.png");
    expect(localImagePath("file:///abs/../x.png", DOC)).toBe("/x.png");
  });
});

describe("localImagePath — non-local src", () => {
  it("S4: is undefined for anything but a local file reference, and the src is left unchanged", () => {
    const nonLocal = [
      "https://h/x.png", "HTTPS://h/x.png", "http://h/x.png", "ftp://h/x.png", " https://h/x.png",
      "data:image/png;base64,AAAA", "blob:http://localhost/u",
      "mailto:a@b.c", "tarmac-card://img/x", "x:y.png",
      "//h/x.png", "file://example.com/x.png", "file:/abs/x.png", "File:/abs/x.png", "file:abs/x.png",
      "", "   ", "#top",
    ];
    for (const src of nonLocal) {
      expect(localImagePath(src, DOC), JSON.stringify(src)).toBeUndefined();
      expect(docImageSrc(src, DOC, 1234), JSON.stringify(src)).toBe(src);
    }
  });
});

describe("localImagePath — query and fragment", () => {
  it("S5: drops everything from the first ? or #", () => {
    expect(localImagePath("x.png?raw=true#top", DOC)).toBe("/r/x.png");
    expect(localImagePath("/abs/x.png#frag", DOC)).toBe("/abs/x.png");
  });
});

describe("localImagePath — percent-decoding", () => {
  it("S6: decodes every escape after the strip, falling back to the whole undecoded path", () => {
    expect(localImagePath("my%20pic.png", DOC)).toBe("/r/my pic.png");
    expect(localImagePath("%E5%9C%96.png", DOC)).toBe("/r/圖.png");
    expect(localImagePath("a%23b.png", DOC)).toBe("/r/a#b.png");
    expect(localImagePath("a%3Fb.png", DOC)).toBe("/r/a?b.png");
    expect(localImagePath("100%.png", DOC)).toBe("/r/100%.png");
    expect(localImagePath("my%20pic%.png", DOC)).toBe("/r/my%20pic%.png");
    // Classified relative before decoding; the empty segment stays, and POSIX reads // as /.
    expect(localImagePath("%2Fx.png", DOC)).toBe("/r//x.png");
  });
});

describe("localImagePath — doc directory", () => {
  // The second docPath carries only valid escapes: with the first one's stray %,
  // a mutant that decodes the directory falls back to literal and still passes.
  it("S7: keeps the doc's directory byte-for-byte, neither decoded nor cut at # or ?", () => {
    expect(localImagePath("img/x.png", "/tmp/my docs 100%#?/圖表/README.md")).toBe(
      "/tmp/my docs 100%#?/圖表/img/x.png",
    );
    expect(localImagePath("img/x.png", "/tmp/a%20b/README.md")).toBe("/tmp/a%20b/img/x.png");
  });
});

describe("localImagePath — surrounding whitespace", () => {
  it("S8: trims ASCII whitespace from both ends first", () => {
    expect(localImagePath("  x.png  ", DOC)).toBe("/r/x.png");
    expect(localImagePath("\tx.png\n", DOC)).toBe("/r/x.png");
    // VT is not one of the five trimmed characters (String.prototype.trim would strip it).
    expect(localImagePath("\vx.png", DOC)).toBe("/r/\vx.png");
  });
});

describe("localImagePath — climbing past the root", () => {
  // One level past the root has no later .. to pop a .. wrongly kept at the root.
  it("S9: never climbs above /", () => {
    expect(localImagePath("../../x.png", DOC)).toBe("/x.png");
    expect(localImagePath("../../../x.png", DOC)).toBe("/x.png");
  });
});

describe("docImageSrc — addressing", () => {
  it("S10: a local src is tarmac-card://img/, one encoded segment, then ?v=mtime", () => {
    const docPath = "/tmp/my docs 100%#?/圖表/README.md";
    expect(docImageSrc("img/x.png", docPath, 1234)).toBe(
      `tarmac-card://img/${encodeURIComponent("/tmp/my docs 100%#?/圖表/img/x.png")}?v=1234`,
    );
    for (const [mtimeMs, v] of [[1234, "1234"], [undefined, "0"]] as const) {
      const url = docImageSrc("img/x.png", docPath, mtimeMs);
      const match = /^tarmac-card:\/\/img\/([^/#?]+)\?v=(\d+)$/.exec(url);
      expect(match, url).not.toBeNull();
      expect(match?.[2]).toBe(v);
      expect(decodeURIComponent(match?.[1] ?? "")).toBe(localImagePath("img/x.png", docPath));
    }
  });
});

describe("docImageSrc — purity", () => {
  // Same guard as cardSrcUrl's: the calls straddle a fake clock tick, so a
  // Date.now()-derived nonce can't hide inside one millisecond.
  it("S11: the same (src, docPath, mtimeMs) gives the same URL", () => {
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date(1_700_000_000_000));
      const first = docImageSrc("img/x.png", DOC, 1_700_000_000_000);
      vi.advanceTimersByTime(5_000);
      const second = docImageSrc("img/x.png", DOC, 1_700_000_000_000);
      expect(second).toBe(first);
    } finally {
      vi.useRealTimers();
    }
  });
});
