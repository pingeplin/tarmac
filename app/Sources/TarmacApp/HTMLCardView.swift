import AppKit
import TarmacKit
import WebKit

/// An HTML card's body: the file running as real JavaScript in a sandboxed
/// frame, exactly as the Tauri app hosts it. The web view holds a small host
/// page whose one element is `<iframe sandbox="allow-scripts">` pointed at
/// `tarmac-card://doc/<path>`; the scheme handler prepends the shim and sets
/// the card's content policy. The shim talks to its parent, the host page,
/// which only carries messages; what they mean is `HTMLCardSession`'s.
///
/// The document is shielded until it is borrowed: a press selects the card
/// and a wheel is relayed, and nothing else reaches it.
@MainActor
final class HTMLCardView: NSView, DocCardBody, WKNavigationDelegate {
    /// A double-click on the shield.
    var onBorrow: (() -> Void)?
    /// The borrowed document saw Escape.
    var onEscapeHome: (() -> Void)?
    /// The console gained an entry; the count is the header badge's.
    var onConsoleChanged: ((Int) -> Void)?

    private let path: String
    private let webView: WKWebView
    private let host: ScreenSpaceHost
    private let messages = ScriptMessageRelay()
    private let shield = CardShieldView()
    private let console = CardConsoleView()

    private var session = HTMLCardSession()
    private var wheel = CardZoom.ScrollRelay()
    private var pageLoaded = false
    private var loadingPage = false
    /// The document's address; it changes, and the document reloads, only when
    /// the file's change time does.
    private var source: String?
    private var borrowed = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(path: String) {
        self.path = path
        webView = CardWebView.make(scripts: [BundledResource.web("card-host.js").text])
        host = ScreenSpaceHost(content: webView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.cgColor
        layer?.masksToBounds = true

        webView.navigationDelegate = self
        webView.underPageBackgroundColor = Theme.bg1
        webView.configuration.userContentController.add(messages, contentWorld: CardWebView.world, name: "card")
        messages.onMessage = { [weak self] message in self?.received(message) }
        host.onResize = { [weak self] _ in self?.layoutDocument() }
        shield.onBorrow = { [weak self] in self?.onBorrow?() }
        shield.onScroll = { [weak self] event in self?.relayWheel(event) }
        console.isHidden = true

        addSubview(host)
        addSubview(shield)
        addSubview(console)
        loadPage()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func loadPage() {
        pageLoaded = false
        loadingPage = true
        webView.loadHTMLString(BundledResource.web("card-host.html").text, baseURL: nil)
    }

    override func layout() {
        super.layout()
        host.frame = bounds
        shield.frame = bounds
        layoutConsole()
    }

    // MARK: - DocCardBody

    func refresh(lastChangedMs: UInt64?) {
        let address = CardURL.src(path: path, mtimeMs: lastChangedMs)
        guard address != source else { return }
        source = address
        loadDocument()
    }

    func setBoardZoom(_ zoom: CGFloat) {
        host.setBoardZoom(zoom)
    }

    // MARK: - Borrow

    /// Lifts or lowers the shield. Borrowing alone does not move the keyboard.
    func setBorrowed(_ on: Bool) {
        borrowed = on
        shield.isHidden = on
    }

    /// Gives the document the keyboard.
    func focusDocument() {
        window?.makeFirstResponder(webView)
        webView.runInCardWorld("tarmacCard.focus()")
    }

    // MARK: - Cull

    func setCulled(_ culled: Bool) {
        session.culled = culled
        post(.cull(culled))
    }

    // MARK: - Console

    func toggleConsole() {
        console.isHidden.toggle()
        needsLayout = true
    }

    private func consoleChanged() {
        console.show(session.console.entries)
        onConsoleChanged?(session.console.entries.count)
        needsLayout = true
    }

    private func layoutConsole() {
        guard !console.isHidden else { return }
        let height = min(console.height(forWidth: bounds.width), (bounds.height * CardConsoleView.maxFraction).rounded(.down))
        console.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
    }

    // MARK: - Document

    private func loadDocument() {
        guard pageLoaded, let source else { return }
        session.reloaded()
        wheel = CardZoom.ScrollRelay()
        layoutDocument()
        webView.callAsyncJavaScript(
            "tarmacCard.load(source)", arguments: ["source": source],
            in: nil, in: CardWebView.world, completionHandler: nil
        )
    }

    /// Sizes the frame the document is laid out in. Magnified, it is laid out
    /// once at `CardZoom.magnifyK` and scaled down to the zoom; otherwise it
    /// is laid out at the card's on-screen size.
    private func layoutDocument() {
        guard pageLoaded else { return }
        let box = CardBox.documentBox(of: CardBox.cardSize(ofBody: bounds.size))
        let magnified = session.mode == .magnify
        let size = CardZoom.iframePx(frame: box, zoom: magnified ? CardZoom.magnifyK : host.settledZoom)
        let scale = magnified ? host.settledZoom / CardZoom.magnifyK : 1
        webView.runInCardWorld("tarmacCard.layout(\(size.width), \(size.height), \(scale))")
    }

    private func post(_ message: CardHostMessage) {
        guard pageLoaded else { return }
        webView.runInCardWorld("tarmacCard.post(\(message.json))")
    }

    private func received(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let parsed = CardConsole.parse(message.body) else { return }
        for effect in session.handle(parsed, borrowed: borrowed) {
            switch effect {
            case .post(let reply): post(reply)
            case .escapeHome: onEscapeHome?()
            case .consoleChanged: consoleChanged()
            case .modeChanged: layoutDocument()
            }
        }
    }

    /// A wheel over the shield scrolls the document: reading is not the touch
    /// the shield is there to stop.
    private func relayWheel(_ event: NSEvent) {
        let magnified = session.mode == .magnify
        func delta(_ scrolling: CGFloat) -> Double {
            Double(CardZoom.scrollDelta(
                CardZoom.wheelDelta(scrollingDelta: scrolling, precise: event.hasPreciseScrollingDeltas),
                zoom: host.zoom, magnify: magnified
            ))
        }
        guard let step = wheel.step(dx: delta(event.scrollingDeltaX), dy: delta(event.scrollingDeltaY)) else { return }
        post(.scroll(dx: step.dx, dy: step.dy))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        loadDocument()
    }

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
        decisionHandler(CardNavigation.htmlCard(request) == .allow ? .allow : .cancel)
    }
}
