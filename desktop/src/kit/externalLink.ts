// Pure URL classifier for clickable card links (doc-card `<a>` clicks, see
// externalLink.test.ts). Absolute http(s) URLs are safe to hand off to the OS
// opener; anything else (relative hrefs, mailto:, javascript:) must stay inert
// so the app webview never navigates itself away.

/** True iff `href` parses as an absolute URL with protocol http: or https:. */
export function isExternalHttpUrl(href: string): boolean {
  try {
    const { protocol } = new URL(href);
    return protocol === "http:" || protocol === "https:";
  } catch {
    return false;
  }
}
