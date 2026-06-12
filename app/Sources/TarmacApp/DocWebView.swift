import AppKit
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
    private var pendingMarkdown: String?

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

    func render(markdown: String) {
        guard pageLoaded else {
            pendingMarkdown = markdown
            return
        }
        guard
            let json = try? JSONSerialization.data(withJSONObject: markdown, options: [.fragmentsAllowed]),
            let literal = String(data: json, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("window.tarmacRender(\(literal));", completionHandler: nil)
    }

    private func loadTemplate() {
        if let url = Bundle.module.url(forResource: "DocTemplate", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // Fallback if the bundled template is missing: plain-text rendering only.
            webView.loadHTMLString(Self.fallbackHTML, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        if let pending = pendingMarkdown {
            pendingMarkdown = nil
            render(markdown: pending)
        }
    }

    private static let fallbackHTML = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { background:#12151a; color:#b9bec8; margin:0; }
        #doc { max-width:720px; margin:0 auto; padding:26px 36px 72px;
               font:400 12px/1.7 ui-monospace, Menlo, monospace; white-space:pre-wrap; }
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
