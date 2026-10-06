import AppKit
import TarmacKit
import WebKit

/// An HTML card's body: the file running as real JavaScript in a sandboxed
/// frame, exactly as the Tauri app hosts it. The web view holds a small host
/// page whose one element is `<iframe sandbox="allow-scripts">` pointed at
/// `tarmac-card://doc/<path>`; the scheme handler prepends the shim and sets
/// the card's content policy. The shim talks to its parent, the host page,
/// which carries messages and says when the document is on screen; what
/// they mean is `HTMLCardSession`'s.
///
/// The document is shielded until it is borrowed: a press selects the card,
/// a wheel is handed on to the web view, and nothing else reaches it.
@MainActor
final class HTMLCardView: NSView, DocCardBody, ThemeFollowing, WKNavigationDelegate {
    /// A double-click on the shield.
    var onBorrow: (() -> Void)?
    /// The borrowed document saw Escape.
    var onEscapeHome: (() -> Void)?
    /// The console gained an entry; the count is the header badge's.
    var onConsoleChanged: ((Int) -> Void)?
    var onScrollChanged: ((ScrollMetrics?) -> Void)?
    var onScrollCoverChanged: (() -> Void)?

    /// The open console lies over the bottom of the document.
    var scrollCover: CGFloat { console.isHidden ? 0 : console.frame.height }
    private var reportedScrollCover: CGFloat = 0

    private let path: String
    private let webView: HTMLCardWebView
    private let host: ScreenSpaceHost
    private let messages = ScriptMessageRelay()
    let shield = CardShieldView()
    private let console = CardConsoleView()

    private var session = HTMLCardSession()
    private var consoleUpdate = CoalescedUpdate()
    private var pageLoaded = false
    /// The theme whose backdrop the host page holds: the one it was loaded
    /// with, or was given since.
    private var backdropGiven: ThemeVariant?
    private var loadingPage = false
    /// The document's address; it changes, and the document reloads, only when
    /// the file's change time does.
    private var source: String?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // Read once: every HTML card loads the same host page and script.
    private static let scripts = [BundledResource.web("card-host.js").text]
    private static let host = BundledResource.web("card-host.html").text

    init(path: String) {
        self.path = path
        webView = CardWebView.make(scripts: Self.scripts, served: .cards, kind: HTMLCardWebView.self)
        host = ScreenSpaceHost(content: webView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        webView.navigationDelegate = self
        webView.configuration.userContentController.add(messages, contentWorld: CardWebView.world, name: "card")
        messages.onMessage = { [weak self] message in self?.received(message) }
        host.onResize = { [weak self] _ in self?.layoutDocument() }
        shield.onBorrow = { [weak self] in self?.onBorrow?() }
        shield.onScroll = { [weak self] event in self?.webView.scrollWheel(with: event) }
        webView.wheelScale = { [weak self] in self?.wheelScale ?? 1 }
        console.isHidden = true

        addSubview(host)
        addSubview(shield)
        addSubview(console)
        themeChanged()
        loadPage()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func loadPage() {
        pageLoaded = false
        loadingPage = true
        backdropGiven = Theme.variant
        coverDocument()
        webView.loadHTMLString(ThemeCSS.page(Self.host, Theme.variant), baseURL: nil)
    }

    /// The host page is given its backdrop and is not loaded again. The
    /// card's own document is sent nothing: one that follows the appearance
    /// restyles itself.
    func themeChanged() {
        layer?.backgroundColor = Theme.bg1.cgColor
        webView.underPageBackgroundColor = Theme.bg1
        showConsole()
        guard pageLoaded, Theme.variant != backdropGiven else { return }
        backdropGiven = Theme.variant
        let backdrop = ThemeCSS.backdrop(Theme.variant)
        webView.callAsyncJavaScript(
            "document.documentElement.style.setProperty(name, value)",
            arguments: ["name": backdrop.name, "value": backdrop.value],
            in: nil, in: CardWebView.world, completionHandler: nil
        )
    }

    override func layout() {
        super.layout()
        host.frame = bounds
        shield.frame = bounds
        layoutConsole()
        reportScrollCover()
    }

    private func reportScrollCover() {
        guard scrollCover != reportedScrollCover else { return }
        reportedScrollCover = scrollCover
        onScrollCoverChanged?()
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

    /// Lifts or lowers the shield, which is the card's record of being
    /// borrowed. Borrowing alone does not move the keyboard.
    func setBorrowed(_ on: Bool) {
        shield.isHidden = on
    }

    /// Gives the document the keyboard.
    func focusDocument() {
        window?.makeFirstResponder(webView)
        webView.runInCardWorld("tarmacCard.focus()")
    }

    /// Whether `responder`, the view with keyboard focus, is the document —
    /// not the console, whose text can be selected and so takes the focus too.
    func documentHoldsKeys(_ responder: NSView) -> Bool {
        responder.isDescendant(of: webView)
    }

    // MARK: - Cull

    func setCulled(_ culled: Bool) {
        session.culled = culled
        post(.cull(culled))
    }

    // MARK: - Console

    func toggleConsole() {
        console.isHidden.toggle()
        showConsole()
        reportScrollCover()
    }

    /// The console gained an entry. A card can log faster than its console
    /// can be drawn, so the badge and the panel catch up at most once per
    /// `CardConsole.refreshInterval`, and the panel only while it is open.
    private func consoleChanged() {
        guard consoleUpdate.changed() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + CardConsole.refreshInterval) { [weak self] in
            guard let self else { return }
            self.consoleUpdate.ran()
            self.onConsoleChanged?(self.session.console.entries.count)
            self.showConsole()
        }
    }

    /// Whether `responder`, the view with keyboard focus, is the console's
    /// text: a press there gives it the keyboard so that it can be selected
    /// and copied, and it takes no typing.
    func consoleHoldsKeys(_ responder: NSView) -> Bool {
        responder.isDescendant(of: console)
    }

    private func showConsole() {
        guard !console.isHidden else { return }
        console.show(session.console.entries)
        needsLayout = true
    }

    private func layoutConsole() {
        guard !console.isHidden else { return }
        let height = console.height(
            forWidth: bounds.width, atMost: (bounds.height * CardConsoleView.maxFraction).rounded(.down)
        )
        console.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
    }

    // MARK: - Document

    /// Before its document is on screen the web view has white to show: the
    /// host page for a frame or two before it is first drawn, then the frame
    /// with no document in it. The document may be dark, so the web view is
    /// out of sight from the moment a page or a document is asked for until
    /// the host page says the document is on screen, and what shows is this
    /// view's own backdrop (#213).
    private func coverDocument() {
        webView.alphaValue = 0
    }

    private func loadDocument() {
        guard pageLoaded, let source else { return }
        session.reloaded()
        coverDocument()
        webView.resetWheel()
        onScrollChanged?(nil)
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

    func scroll(to offset: Double) {
        post(.scrollTo(offset))
    }

    private func received(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let parsed = CardConsole.parse(message.body) else { return }
        for effect in session.handle(parsed, borrowed: shield.isHidden) {
            switch effect {
            case .post(let reply): post(reply)
            case .escapeHome: onEscapeHome?()
            case .consoleChanged: consoleChanged()
            case .modeChanged: layoutDocument()
            case .scrollChanged(let metrics): onScrollChanged?(metrics)
            case .documentShown: webView.alphaValue = 1
            }
        }
    }

    /// The zoom is the live one: while it settles, the card's stretch carries
    /// the difference, so a document unit is `zoom / magnifyK` of a point
    /// throughout.
    private var wheelScale: CGFloat {
        CardZoom.wheelScale(zoom: host.zoom, magnify: session.mode == .magnify)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        themeChanged()
        loadDocument()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onScrollChanged?(nil)
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
