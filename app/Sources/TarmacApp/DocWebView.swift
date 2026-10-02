import AppKit
import TarmacKit
import WebKit

/// A markdown doc card's body: the doc rendered by marked into a page laid out
/// at the card's on-screen size. The page keeps the doc's raw HTML and never
/// runs it. The text can be selected and copied the usual way, so the web view
/// takes keyboard focus when it is pressed.
@MainActor
final class DocWebView: NSView, DocCardBody, WKNavigationDelegate {
    /// Where a clicked http(s) link goes.
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// The pointer is on a link of the doc, as the page last reported it. A
    /// press is judged before the page sees it, so this is known ahead of one.
    private(set) var pointerIsOverLink = false

    /// A text control of the doc's raw HTML has the page's focus.
    private(set) var isEditingText = false

    private let path: String
    private let webView: WKWebView
    private let host: ScreenSpaceHost
    private let images = ScriptRequestRelay()
    private let links = ScriptMessageRelay()
    private let hover = ScriptMessageRelay()
    private let editing = ScriptMessageRelay()

    private var pageLoaded = false
    private var loadingPage = false
    private var markdown: String?
    private var lastChangedMs: UInt64?
    /// Reads are answered off the main thread; only the latest one is shown.
    private var reads = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(path: String) {
        self.path = path
        webView = CardWebView.make(
            scripts: [BundledResource.web("marked.umd.js").text, BundledResource.web("doc-render.js").text],
            served: .docImages
        )
        host = ScreenSpaceHost(content: webView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.cgColor

        webView.navigationDelegate = self
        webView.underPageBackgroundColor = Theme.bg1
        webView.configuration.userContentController.addScriptMessageHandler(
            images, contentWorld: CardWebView.world, name: "docImages"
        )
        images.onRequest = { [weak self] message in self?.imageSources(for: message.body) }
        webView.configuration.userContentController.add(links, contentWorld: CardWebView.world, name: "docLink")
        links.onMessage = { [weak self] message in self?.linkClicked(message) }
        webView.configuration.userContentController.add(hover, contentWorld: CardWebView.world, name: "docOverLink")
        hover.onMessage = { [weak self] message in self?.pointerIsOverLink = message.body as? Bool ?? false }
        webView.configuration.userContentController.add(editing, contentWorld: CardWebView.world, name: "docEditing")
        editing.onMessage = { [weak self] message in self?.isEditingText = message.body as? Bool ?? false }
        host.onResize = { [weak self] size in self?.layoutPage(viewport: size) }
        addSubview(host)
        loadPage()
    }

    private func loadPage() {
        pageLoaded = false
        pointerIsOverLink = false
        isEditingText = false
        loadingPage = true
        webView.loadHTMLString(BundledResource.docTemplate.text, baseURL: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    // MARK: - DocCardBody

    func refresh(lastChangedMs: UInt64?) {
        self.lastChangedMs = lastChangedMs
        reads += 1
        let read = reads
        let path = self.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let markdown = DocSource.markdown(path: path, contents: FileBytes.read(path: path))
            DispatchQueue.main.async { [weak self] in
                guard let self, read == self.reads else { return }
                self.markdown = markdown
                self.render()
            }
        }
    }

    func setBoardZoom(_ zoom: CGFloat) {
        host.setBoardZoom(zoom)
    }

    // MARK: - Page

    private func render() {
        guard pageLoaded, let markdown else { return }
        webView.callAsyncJavaScript(
            "await tarmacDoc.render(markdown)", arguments: ["markdown": markdown],
            in: nil, in: CardWebView.world, completionHandler: nil
        )
    }

    /// Tells the page the zoom and the card width it is laid out for, and the
    /// viewport height it is about to have.
    private func layoutPage(viewport: CGSize) {
        guard pageLoaded else { return }
        let cardWidth = CardBox.cardSize(ofBody: bounds.size).width
        webView.runInCardWorld("tarmacDoc.layout(\(host.settledZoom), \(cardWidth), \(viewport.height))")
    }

    /// The `src` each image of a render is loaded from: a local file through
    /// the card scheme, anything else as written.
    private func imageSources(for body: Any) -> [String] {
        (body as? [String] ?? []).map { DocImage.src($0, docPath: path, mtimeMs: lastChangedMs) }
    }

    /// A link in the doc was clicked; the message is its `href` as written.
    /// Only an absolute http(s) one opens, and every other is inert.
    private func linkClicked(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let href = message.body as? String,
              let url = ExternalLink.destination(href: href)
        else { return }
        openExternal(url)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        layoutPage(viewport: webView.frame.size)
        render()
    }

    /// The system reclaimed the page's process; the page is gone with it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadPage()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let request = navigationAction.cardRequest(pageLoad: loadingPage)
        loadingPage = false
        decisionHandler(CardNavigation.doc(request) == .allow ? .allow : .cancel)
    }
}
