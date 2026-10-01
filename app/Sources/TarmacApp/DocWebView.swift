import AppKit
import TarmacKit
import WebKit

/// Focus rule (crib-state §9): the terminal is "the body" — a click in a doc
/// body must not move keyboard focus off it. Scroll-on-hover and link clicks
/// are pointer-routed and unaffected.
@MainActor
private final class NonFocusableWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

/// The shared markdown viewer (peek body + pinned doc tiles): a WKWebView
/// loading DocTemplate.html and rendering through window.tarmacRender, which
/// preserves the reading position across re-renders.
@MainActor
final class DocWebView: NSView, WKNavigationDelegate {
    private let webView: WKWebView
    private var pageLoaded = false
    /// The last markdown handed to `render` — the source of truth re-applied on
    /// every honored `didFinish` (so a pre-load render, an initial load, and a
    /// post-suspend resume all repaint from one place, idempotently). P5.5.
    private var lastMarkdown: String?
    /// P5.5: true while parked on about:blank (the board is inactive). Gates the
    /// `didFinish` callback so the about:blank load never marks the doc page loaded.
    private var suspended = false
    /// P5.5: the reading position captured at suspend, re-applied after the
    /// resume re-render (a fresh template load resets scrollTop to 0).
    private var savedScrollY: CGFloat = 0
    /// P5.5: set on resume so the next honored `didFinish` restores `savedScrollY`.
    private var restoreScrollOnLoad = false
    /// The last device-scale factor the board pushed (always ≥2 — see
    /// `BoardView.docDeviceScaleOverride`). Re-asserted on every honored
    /// `didFinish` so a resumed/reloaded web process re-rasterizes its tiles at
    /// that density rather than the window backing scale. `0` is the initial
    /// "never pushed yet" sentinel.
    private var lastDeviceScaleFactor: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        webView = NonFocusableWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = Theme.bg1
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        loadTemplate()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// Copies the web view's current text selection to the general pasteboard.
    /// The doc body is intentionally non-focusable (a doc click must not pull
    /// keyboard focus off the prime terminal — crib §9), which also means the
    /// standard `copy:` action never reaches it through the responder chain. The
    /// controller routes ⌘C here for the focused doc card instead. Plain text by
    /// design (the doc is a reading surface, not a rich-text source).
    func copySelectionToPasteboard() {
        webView.evaluateJavaScript("window.getSelection().toString()") { result, _ in
            guard let text = result as? String, !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    func render(markdown: String) {
        // Cache unconditionally (even mid-load / while suspended) so the next
        // honored didFinish repaints the latest content.
        lastMarkdown = markdown
        guard pageLoaded else { return }
        guard
            let json = try? JSONSerialization.data(withJSONObject: markdown, options: [.fragmentsAllowed]),
            let literal = String(data: json, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("window.tarmacRender(\(literal));", completionHandler: nil)
    }

    /// P5.5: suspend the view — cache stays, park on about:blank to free the web
    /// content process. Captures the scroll offset first (async) so resume can
    /// restore the reading position. No-op if already suspended.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        // Guarded on `suspended` so a resume() that races ahead of the async scroll
        // capture (a rapid switch-back) is not clobbered by a late about:blank load.
        let parkOnBlank: () -> Void = { [weak self] in
            guard let self, self.suspended else { return }
            self.pageLoaded = false
            self.webView.load(URLRequest(url: URL(string: "about:blank")!))
        }
        if pageLoaded {
            webView.evaluateJavaScript("(document.scrollingElement||document.documentElement).scrollTop") { [weak self] result, _ in
                if let n = result as? NSNumber { self?.savedScrollY = CGFloat(n.doubleValue) }
                parkOnBlank()
            }
        } else {
            // Mid-load (e.g. a re-suspend before a resume's template finished):
            // keep the last captured position rather than zeroing it, so a rapid
            // leave→arrive→leave doesn't lose the reading position. It defaults to
            // 0 before any successful render, which is the correct first value.
            parkOnBlank()
        }
    }

    /// P5.5: resume a suspended view — reload the template; the honored didFinish
    /// re-renders the cached markdown and restores the saved scroll. No-op if the
    /// view was never suspended (e.g. a board on its first arrive).
    func resume() {
        guard suspended else { return }
        suspended = false
        restoreScrollOnLoad = true
        loadTemplate()
    }

    /// Crisp-zoom hook (the board pushes this on every zoom / display change).
    /// Sets the web content process's deviceScaleFactor to the board-computed
    /// effective scale (≥2, oversampled — see `BoardView.docDeviceScaleOverride`)
    /// so WebKit re-rasterizes its tiles at that pixel density — countering the
    /// card's `frame≠bounds` CATransform upscale and oversampling on a low-DPI
    /// screen — WITHOUT changing the CSS viewport, so text never re-wraps. This is
    /// the doc-card analogue of `CardView.applyContentScale` for native layers,
    /// but routes through the only knob WebKit's out-of-process tiles obey.
    func applyZoomScale(_ effectiveScale: CGFloat) {
        // Re-raster is an async paint round-trip — skip non-finite / negative
        // values and no-op when the scale hasn't actually changed (every pan
        // reprojects, but only a zoom / display change should re-raster).
        guard effectiveScale.isFinite, effectiveScale >= 0,
              abs(effectiveScale - lastDeviceScaleFactor) > 0.0001 else { return }
        lastDeviceScaleFactor = effectiveScale
        applyDeviceScaleFactor(effectiveScale)
    }

    /// Pushes WebKit's private `_setOverrideDeviceScaleFactor:` SPI
    /// (`WKWebViewPrivate.h`, macOS 10.11+) — the web content process's device
    /// scale factor, i.e. `window.devicePixelRatio`. WebKit re-rasterizes its
    /// tiles at this density with NO CSS-layout change, so doc text never
    /// re-wraps. It's the one knob that reaches WebKit's out-of-process tiles,
    /// which ignore an externally-poked `CALayer.contentsScale`. `0` resets to
    /// the window backing scale.
    ///
    /// Invoked via an IMP cast, not a typed `@objc`-protocol cast: that latter
    /// resolves through `-conformsToProtocol:`, which a class that merely
    /// *responds* to the selector (without declaring conformance) fails — so the
    /// cast would silently return nil. `perform(_:with:)` is also wrong here: it
    /// boxes the `CGFloat` argument to `id` and mangles it. The IMP cast passes
    /// the `CGFloat` in a register with the correct C ABI. Guarded on
    /// `responds(to:)` so a future OS dropping the selector no-ops, never crashes.
    private func applyDeviceScaleFactor(_ factor: CGFloat) {
        let sel = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
        guard webView.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        let imp = webView.method(for: sel)
        unsafeBitCast(imp, to: Fn.self)(webView, sel, factor)
    }

    private func loadTemplate() {
        pageLoaded = false
        // Prefer Contents/Resources via Bundle.main. In a code-signed .app the
        // SwiftPM `Bundle.module` accessor looks for the resource bundle at the
        // .app ROOT (Bundle.main.bundleURL/<Pkg>_<Target>.bundle), which cannot be
        // code-signed there ("unsealed contents present in the bundle root") — so
        // bundle.sh copies DocTemplate.html flat into Contents/Resources and we
        // resolve it through Bundle.main. Bundle.module stays as the fallback for
        // `make run` / tests, where the template lives in the sibling .bundle next
        // to the executable; there Bundle.main misses, the `??` forces
        // Bundle.module, and its mainPath resolves without fatal-erroring.
        let url = Bundle.main.url(forResource: "DocTemplate", withExtension: "html")
            ?? Bundle.module.url(forResource: "DocTemplate", withExtension: "html")
        if let url {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // Fallback if the bundled template is missing: plain-text rendering only.
            webView.loadHTMLString(Self.fallbackHTML, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // P5.5: ignore the about:blank load's didFinish (it fires while suspended);
        // only the real doc template marks the page loaded.
        guard DocSuspend.shouldHonorDidFinish(suspended: suspended) else { return }
        pageLoaded = true
        // Repaint from the cache (idempotent — safe against a raced callback).
        if let md = lastMarkdown { render(markdown: md) }
        // Re-assert the render density: a fresh template load (initial or post-
        // resume) starts the web process at the window backing scale, so the last
        // board-pushed factor must be re-sent or the doc reads blurry until the
        // next zoom / display change. Skipped only before the board's first push.
        if lastDeviceScaleFactor > 0 { applyDeviceScaleFactor(lastDeviceScaleFactor) }
        if restoreScrollOnLoad {
            restoreScrollOnLoad = false
            webView.evaluateJavaScript(DocSuspend.scrollRestoreJS(scrollTop: savedScrollY), completionHandler: nil)
        }
    }

    private static let fallbackHTML = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { background:#2b3036; color:#ced3d7; margin:0; }
        #doc { max-width:720px; margin:0 auto; padding:26px 36px 72px;
               font:400 16px/1.7 ui-monospace, Menlo, monospace; white-space:pre-wrap; }
        </style></head><body><div id="doc"></div><script>
        window.tarmacRender = function (md) {
          var s = document.scrollingElement || document.documentElement;
          var y = s.scrollTop;
          document.getElementById("doc").textContent = md == null ? "" : String(md);
          s.scrollTop = y;
        };
        </script></body></html>
        """
}
