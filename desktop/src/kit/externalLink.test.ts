import { describe, it, expect } from "vitest";
import { isExternalHttpUrl } from "./externalLink";

describe("isExternalHttpUrl", () => {
  // Absolute http(s) URLs are the only hrefs safe to hand to the OS opener.
  it("accepts absolute https URLs", () => {
    expect(isExternalHttpUrl("https://x.com")).toBe(true);
  });

  it("accepts absolute http URLs", () => {
    expect(isExternalHttpUrl("http://x.com")).toBe(true);
  });

  // Relative hrefs and non-http(s) schemes must stay inert — never handed to
  // the opener, never navigated in-app.
  it("rejects relative hrefs", () => {
    expect(isExternalHttpUrl("#section")).toBe(false);
    expect(isExternalHttpUrl("/local/path")).toBe(false);
  });

  it("rejects non-http(s) schemes", () => {
    expect(isExternalHttpUrl("mailto:a@b.com")).toBe(false);
    expect(isExternalHttpUrl("javascript:alert(1)")).toBe(false);
  });
});
