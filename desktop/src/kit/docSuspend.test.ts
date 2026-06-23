import { describe, it, expect } from "vitest";
import { shouldHonorDidFinish, scrollRestoreJS } from "./docSuspend";

// Port of DocSuspendTests.swift (P5.5): the pure helpers behind doc-webview
// suspension — the load-callback guard and the scroll-restore JS.
describe("DocSuspend", () => {
  it("honors didFinish only when not suspended", () => {
    // The real template load (not suspended) is honored…
    expect(shouldHonorDidFinish(false)).toBe(true);
    // …the about:blank load issued during suspend is dropped.
    expect(shouldHonorDidFinish(true)).toBe(false);
  });

  it("scrollRestoreJS emits the offset", () => {
    expect(scrollRestoreJS(0)).toBe(
      "var s=document.scrollingElement||document.documentElement; if(s){s.scrollTop=0.0;}",
    );
    expect(scrollRestoreJS(128.5)).toBe(
      "var s=document.scrollingElement||document.documentElement; if(s){s.scrollTop=128.5;}",
    );
  });

  it("scrollRestoreJS is well-formed for a large offset", () => {
    const js = scrollRestoreJS(99999);
    // Single statement guarded on the scrolling element, ending with a brace.
    expect(js.includes("scrollTop=")).toBe(true);
    expect(js.endsWith(";}")).toBe(true);
    expect(js.includes("document.scrollingElement||document.documentElement")).toBe(true);
  });
});
