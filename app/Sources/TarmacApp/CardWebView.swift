import AppKit
import TarmacKit
import WebKit

/// The web view a card's page runs in, and how the app's own script in it is
/// kept apart from the page's.
@MainActor
enum CardWebView {
    /// The app's scripts run in this world, not the page's: a script the page
    /// carries sees neither them nor the message handlers, which exist only here.
    static let world = WKContentWorld.world(name: "tarmac")

    /// Nothing a card loads is kept: no cookies, cache or storage outlive the app.
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    /// A web view that is served `tarmac-card://` by `handler` and runs
    /// `scripts`, in order, in the app's world once its page has loaded.
    static func make(scripts: [String], served handler: CardSchemeHandler) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.setURLSchemeHandler(handler, forURLScheme: CardSchemeHandler.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        for source in scripts {
            configuration.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world
            ))
        }
        return WKWebView(frame: .zero, configuration: configuration)
    }
}

extension WKWebView {
    /// Runs `script` in the app's world.
    func runInCardWorld(_ script: String) {
        evaluateJavaScript(script, in: nil, in: CardWebView.world, completionHandler: nil)
    }
}

/// Carries a page's messages to a closure. A content controller holds its
/// handlers strongly and the view that owns the web view is what answers them;
/// with this between the two, closing a card frees its web view.
@MainActor
final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage?(message)
    }
}

/// `ScriptMessageRelay` for a message the page awaits an answer to.
@MainActor
final class ScriptRequestRelay: NSObject, WKScriptMessageHandlerWithReply {
    var onRequest: ((WKScriptMessage) -> Any?)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        replyHandler(onRequest?(message), nil)
    }
}

extension WKNavigationAction {
    /// The action as `CardNavigation` decides it. `pageLoad` says this is the
    /// app loading the card's own page.
    func cardRequest(pageLoad: Bool) -> CardNavigation.Request {
        let target: CardNavigation.Target
        if let frame = targetFrame {
            target = frame.isMainFrame ? .mainFrame : .subframe
        } else {
            target = .newWindow
        }
        return CardNavigation.Request(url: request.url?.absoluteString ?? "", target: target, pageLoad: pageLoad)
    }
}
