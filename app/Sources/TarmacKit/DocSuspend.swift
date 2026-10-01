import CoreGraphics

/// Pure helpers for P5.5 doc-webview suspension (multi-board perf). A board that
/// goes inactive parks its doc `WKWebView`s on about:blank to free the heavy web
/// content process, caches the last markdown, and re-renders + restores scroll on
/// return. Kept in TarmacKit so the load-callback guard + the scroll-restore JS
/// are unit-tested away from WebKit (`DocWebView` is not unit-tested by design).
public enum DocSuspend {
    /// Whether a `WKWebView` `didFinish` callback should be honored — i.e. it is
    /// the real doc template finishing, not the about:blank load issued during
    /// suspend (which fires while `suspended` is still true). Rendering from the
    /// cached markdown then makes a raced callback idempotent rather than lossy.
    public static func shouldHonorDidFinish(suspended: Bool) -> Bool {
        !suspended
    }

    /// The JS that restores a saved vertical scroll offset after the doc template
    /// reloads on resume. A fresh template load resets scrollTop to 0, so the
    /// in-render scroll-preserve in `window.tarmacRender` is not enough — the
    /// offset must be re-applied explicitly after the re-render.
    public static func scrollRestoreJS(scrollTop: CGFloat) -> String {
        "var s=document.scrollingElement||document.documentElement; if(s){s.scrollTop=\(scrollTop);}"
    }
}
