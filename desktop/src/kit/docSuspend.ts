// Port of TarmacKit/DocSuspend.swift — pure helpers for P5.5 doc-webview
// suspension (multi-board perf). A board that goes inactive parks its doc
// webviews on about:blank to free the heavy web content process, caches the last
// markdown, and re-renders + restores scroll on return. Kept pure so the
// load-callback guard + the scroll-restore JS are unit-tested away from WebKit.

/**
 * Whether a webview `didFinish` callback should be honored — i.e. it is the real
 * doc template finishing, not the about:blank load issued during suspend (which
 * fires while `suspended` is still true). Rendering from the cached markdown then
 * makes a raced callback idempotent rather than lossy.
 */
export function shouldHonorDidFinish(suspended: boolean): boolean {
  return !suspended;
}

/**
 * Render a number the way Swift interpolates a `Double`/`CGFloat`: a whole value
 * still carries a trailing `.0` (`0` -> "0.0", `99999` -> "99999.0"), while a
 * fractional value prints its decimals (`128.5` -> "128.5"). The emitted JS must
 * match the Swift string byte-for-byte, so the scroll offset is formatted this way.
 */
function swiftDoubleString(value: number): string {
  if (Number.isFinite(value) && Number.isInteger(value)) {
    return `${value}.0`;
  }
  return String(value);
}

/**
 * The JS that restores a saved vertical scroll offset after the doc template
 * reloads on resume. A fresh template load resets scrollTop to 0, so the
 * in-render scroll-preserve in `window.tarmacRender` is not enough — the offset
 * must be re-applied explicitly after the re-render. The string must reference
 * the scroll offset.
 */
export function scrollRestoreJS(scrollTop: number): string {
  return `var s=document.scrollingElement||document.documentElement; if(s){s.scrollTop=${swiftDoubleString(scrollTop)};}`;
}
