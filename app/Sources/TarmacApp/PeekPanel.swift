import AppKit
import WebKit
import QuartzCore

/// kbd chip per crib: mono 500 10px muted, bg2, 1px line border with a 2px
/// bottom edge, radius 4, padding 1px 5px.
final class KbdChipView: NSView {
    private let label: NSTextField
    private let size: NSSize

    init(_ text: String) {
        label = NSTextField(labelWithString: text)
        label.font = Theme.mono(10, weight: .medium)
        label.textColor = Theme.muted
        let textSize = label.intrinsicContentSize
        size = NSSize(width: textSize.width + 10, height: textSize.height + 3)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4

        let bottomEdge = NSView(frame: NSRect(x: 1, y: 0, width: size.width - 2, height: 1))
        bottomEdge.wantsLayer = true
        bottomEdge.layer?.backgroundColor = Theme.line.cgColor
        bottomEdge.autoresizingMask = [.width]
        addSubview(bottomEdge)

        label.frame = NSRect(x: 5, y: 2, width: textSize.width, height: textSize.height)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { size }
}

@MainActor
final class PeekPanel: NSView, WKNavigationDelegate {
    private let header = NSView()
    private let repoDot = NSView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let escChip = KbdChipView("esc")
    private let leftBorder = NSView()
    private let headerHairline = NSView()
    private let webView: WKWebView

    private var pageLoaded = false
    private var pendingMarkdown: String?
    private(set) var currentPath: String?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.cgColor

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowOffset = NSSize(width: -26, height: 0)
        shadow.shadowBlurRadius = 30
        self.shadow = shadow

        leftBorder.wantsLayer = true
        leftBorder.layer?.backgroundColor = Theme.line.cgColor
        addSubview(leftBorder)

        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bg2.cgColor
        addSubview(header)

        headerHairline.wantsLayer = true
        headerHairline.layer?.backgroundColor = Theme.lineSoft.cgColor
        header.addSubview(headerHairline)

        repoDot.wantsLayer = true
        repoDot.layer?.cornerRadius = 3.5
        header.addSubview(repoDot)

        pathLabel.font = Theme.mono(11)
        pathLabel.textColor = Theme.muted
        pathLabel.lineBreakMode = .byTruncatingHead
        header.addSubview(pathLabel)

        header.addSubview(escChip)

        webView.navigationDelegate = self
        webView.underPageBackgroundColor = Theme.bg1
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)

        loadTemplate()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        leftBorder.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
        header.frame = NSRect(x: 1, y: 0, width: bounds.width - 1, height: 36)
        webView.frame = NSRect(x: 1, y: 36, width: bounds.width - 1, height: max(0, bounds.height - 36))

        let hh = header.bounds.height
        headerHairline.frame = NSRect(x: 0, y: 0, width: header.bounds.width, height: 1)
        repoDot.frame = NSRect(x: 12, y: (hh - 7) / 2, width: 7, height: 7)
        let chipSize = escChip.intrinsicContentSize
        escChip.frame = NSRect(
            x: header.bounds.width - 12 - chipSize.width,
            y: (hh - chipSize.height) / 2,
            width: chipSize.width,
            height: chipSize.height
        )
        let labelHeight = pathLabel.intrinsicContentSize.height
        let labelX: CGFloat = 12 + 7 + 8
        pathLabel.frame = NSRect(
            x: labelX,
            y: (hh - labelHeight) / 2,
            width: max(0, escChip.frame.minX - 8 - labelX),
            height: labelHeight
        )
    }

    func present(path: String, markdown: String) {
        currentPath = path
        let home = NSHomeDirectory()
        pathLabel.stringValue = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let repoKey = (path as NSString).deletingLastPathComponent
        repoDot.layer?.backgroundColor = Theme.repoColor(for: (repoKey as NSString).lastPathComponent).cgColor
        render(markdown: markdown)
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
