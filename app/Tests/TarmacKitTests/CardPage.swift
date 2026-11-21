import WebKit
import XCTest
@testable import TarmacKit

/// An HTML card page in an offscreen `WKWebView`, with the shipped shim placed
/// after the doctype as `CardProtocol` places it. At the top level
/// `window.parent` is the window, so the shim takes the page's own post as the
/// host's.
///
/// The page is driven by spinning the main run loop; the `async` forms of
/// `evaluateJavaScript` failed inside `swift test`.
@MainActor
enum CardPage {
    struct Timeout: Error { let what: String }

    static func shim(fonts: CardFontVariables? = nil) throws -> String {
        let text = try CardShimSource.text()
        return fonts?.filling(text) ?? text
    }

    static func spin(until done: () -> Bool, _ what: String) throws {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { throw Timeout(what: what) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// The script's value, as JSON text decoded; `prelude` is declared first.
    static func eval(_ view: WKWebView, _ script: String, prelude: String = "") throws -> Any? {
        var out: Any?
        var failure: Error?
        var done = false
        view.evaluateJavaScript("JSON.stringify((function(){ \(prelude)\n return (\(script)); })())") { value, error in
            out = value
            failure = error
            done = true
        }
        try spin(until: { done }, "evaluate \(script)")
        if let failure { throw failure }
        guard let text = out as? String else { return nil }
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    /// `page` loaded in a 1400×900 view; then `zoom` posted, if any.
    static func load(_ page: String, zoom: Double?) throws -> WKWebView {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        view.loadHTMLString(page, baseURL: nil)
        try spin(until: { !view.isLoading }, "load")
        if let zoom {
            _ = try eval(view, "(window.postMessage({ tarmac: 'zoom', z: \(zoom) }, '*'), 0)")
            try spin(until: { ((try? eval(view, "document.documentElement.style.zoom")) as? String).flatMap(Double.init) == zoom }, "zoom \(zoom)")
            _ = try eval(view, "document.body.offsetWidth")
        }
        return view
    }

    static func snapshot(_ view: WKWebView) throws -> NSBitmapImageRep {
        var image: NSImage?
        var done = false
        view.takeSnapshot(with: nil) { shot, _ in
            image = shot
            done = true
        }
        try spin(until: { done }, "snapshot")
        let tiff = try XCTUnwrap(image?.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }
}
