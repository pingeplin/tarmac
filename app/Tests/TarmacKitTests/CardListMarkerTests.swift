import WebKit
import XCTest
@testable import TarmacKit

/// The list markers of a magnified HTML card (spec 2611.0019), checked in real
/// WebKit: the shipped `card_shim.js` runs in an offscreen `WKWebView`, in a
/// page that posts the zoom to itself. At the top level `window.parent` is the
/// window, so the shim takes the page's own post as the host's. The bug and
/// its fix are layout, which the JavaScriptCore stand-in of `CardShimTests`
/// cannot show.
///
/// The page is driven by spinning the main run loop; the `async` forms of
/// `evaluateJavaScript` failed inside `swift test`.
@MainActor
final class CardListMarkerTests: XCTestCase {
    private struct Timeout: Error { let what: String }

    private static let long = "words of a list item that is long enough to wrap onto a second line"

    private static let lines = """
    function lines(el) {
      const r = document.createRange(); r.selectNodeContents(el);
      const by = new Map();
      for (const q of r.getClientRects()) {
        if (q.width < 1) continue;
        const k = Math.round(q.top);
        by.set(k, Math.min(by.has(k) ? by.get(k) : 1e9, q.left));
      }
      return [...by.entries()].sort((a, b) => a[0] - b[0]).map(e => e[1]);
    }
    """

    private func shim(fonts: CardFontVariables? = nil) throws -> String {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(
            contentsOf: app.appendingPathComponent("Sources/TarmacApp/Resources/Web/card_shim.js"), encoding: .utf8
        )
        return fonts?.filling(text) ?? text
    }

    private func spin(until done: () -> Bool, _ what: String) throws {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { throw Timeout(what: what) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// The script's value, as JSON text decoded.
    private func eval(_ view: WKWebView, _ script: String) throws -> Any? {
        var out: Any?
        var failure: Error?
        var done = false
        view.evaluateJavaScript("JSON.stringify((function(){ \(Self.lines)\n return (\(script)); })())") { value, error in
            out = value
            failure = error
            done = true
        }
        try spin(until: { done }, "evaluate \(script)")
        if let failure { throw failure }
        guard let text = out as? String else { return nil }
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private func number(_ view: WKWebView, _ script: String) throws -> Double {
        try XCTUnwrap(eval(view, script) as? Double, script)
    }

    /// A card page with `body`, the author's `css`, and the shim placed after
    /// the doctype as `CardProtocol` places it; then `zoom` posted, if any.
    private func card(_ body: String, css: String = "", zoom: Double?, fonts: CardFontVariables? = nil) throws -> WKWebView {
        let page = """
        <!doctype html><script>\(try shim(fonts: fonts))</script><html><head><meta charset="utf-8"><style>
        body { margin: 0; padding: 20px 60px; width: 300px; font: 14px -apple-system, sans-serif; }
        ul, ol { margin: 0; }
        \(css)
        </style></head><body>\(body)</body></html>
        """
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        view.loadHTMLString(page, baseURL: nil)
        try spin(until: { !view.isLoading }, "load")
        if let zoom {
            _ = try eval(view, "(window.postMessage({ tarmac: 'zoom', z: \(zoom) }, '*'), 0)")
            try spin(until: { ((try? self.eval(view, "document.documentElement.style.zoom")) as? String).flatMap(Double.init) == zoom }, "zoom \(zoom)")
            _ = try eval(view, "document.body.offsetWidth")
        }
        return view
    }

    private func firstAndWrapped(_ body: String, css: String = "", zoom: Double) throws -> [Double] {
        let view = try card(body, css: css, zoom: zoom)
        let lefts = try XCTUnwrap(eval(view, "lines(document.getElementById('it'))") as? [Double])
        XCTAssertGreaterThanOrEqual(lefts.count, 2, "the item wraps")
        return Array(lefts.prefix(2))
    }

    private func assertLinesInPlace(_ body: String, css: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
        let reference = try firstAndWrapped(body, css: css, zoom: 1)[0] * 3
        let zoomed = try firstAndWrapped(body, css: css, zoom: 3)
        XCTAssertEqual(zoomed[0], zoomed[1], accuracy: 1, "first line against wrapped line", file: file, line: line)
        XCTAssertEqual(zoomed[0], reference, accuracy: 1, "first line against the zoom-1 left", file: file, line: line)
    }

    // MARK: - Layout (G1)

    func testS1APlainUlItemsFirstLineStaysWithItsWrappedLinesAtZoom3() throws {
        try assertLinesInPlace("<ul><li id=it>First \(Self.long)</li></ul>")
    }
}
