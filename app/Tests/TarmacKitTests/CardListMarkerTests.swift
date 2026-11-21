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
        let text = try CardShimSource.text()
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
    private func card(
        _ body: String, css: String = "", zoom: Double?, fonts: CardFontVariables? = nil, then script: String? = nil
    ) throws -> WKWebView {
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
        if let script { _ = try eval(view, "(\(script), 0)") }
        return view
    }

    private func firstAndWrapped(_ view: WKWebView) throws -> [Double] {
        let lefts = try XCTUnwrap(eval(view, "lines(document.getElementById('it'))") as? [Double])
        XCTAssertGreaterThanOrEqual(lefts.count, 2, "the item wraps")
        return Array(lefts.prefix(2))
    }

    /// Checks the item `#it` at zoom 3 against itself at zoom 1, and gives
    /// back the zoom-3 page.
    @discardableResult
    private func assertLinesInPlace(
        _ body: String, then script: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) throws -> WKWebView {
        let reference = try firstAndWrapped(card(body, zoom: 1, then: script))[0] * 3
        let view = try card(body, zoom: 3, then: script)
        let zoomed = try firstAndWrapped(view)
        XCTAssertEqual(zoomed[0], zoomed[1], accuracy: 1, "first line against wrapped line", file: file, line: line)
        XCTAssertEqual(zoomed[0], reference, accuracy: 1, "first line against the zoom-1 left", file: file, line: line)
        return view
    }

    // MARK: - Layout (G1)

    func testS1APlainUlItemsFirstLineStaysWithItsWrappedLinesAtZoom3() throws {
        try assertLinesInPlace("<ul><li id=it>First \(Self.long)</li></ul>")
    }

    func testS2OlItemsFirstLinesStayWithTheirWrappedLinesAtZoom3() throws {
        try assertLinesInPlace("<ol><li id=it>First \(Self.long)</li></ol>")
        try assertLinesInPlace("<ol start=10><li id=it>First \(Self.long)</li></ol>")
        try assertLinesInPlace("<ol type=I start=8 style='font-size:22px'><li id=it>First \(Self.long)</li></ol>")
    }

    func testS14AnItemWhoseFirstChildIsABlockHasItsFirstLineInPlace() throws {
        for (list, child) in [("ul", "p"), ("ol", "div")] {
            let body = "<\(list)><li id=li><\(child) id=it>First \(Self.long)</\(child)></li></\(list)>"
            let view = try assertLinesInPlace(body)
            XCTAssertEqual(try mark(view, "#li"), list == "ul" ? "disc" : "decimal", "S14 \(child)")
        }
    }

    func testS22AnItemInAScrolledBoxHasItsFirstLineInPlace() throws {
        let filler = (1...6).map { "<li>filler \($0) \(Self.long)</li>" }.joined()
        let body = "<div id=box style='height:150px;overflow:auto'><ul>\(filler)<li id=it>First \(Self.long)</li></ul></div>"
        let view = try assertLinesInPlace(body, then: "document.getElementById('box').scrollTop = 120")
        XCTAssertEqual(try mark(view, "#it"), "disc")
    }

    // MARK: - Which items are marked (D3, D4, G2, G3)

    private static let control = "<ul id=control><li>a</li><li>b</li></ul>"

    private func mark(_ view: WKWebView, _ selector: String) throws -> String? {
        try eval(view, "document.querySelector(\(json(selector))).getAttribute('data-tarmac-marker')") as? String
    }

    private func marks(_ view: WKWebView, _ selector: String) throws -> [String?] {
        let value = try eval(view, "[...document.querySelectorAll(\(json(selector)))].map(li => li.getAttribute('data-tarmac-marker'))")
        return try XCTUnwrap(value as? [Any]).map { $0 as? String }
    }

    private func style(_ view: WKWebView, _ selector: String, _ property: String, pseudo: String? = nil) throws -> [String] {
        let pseudoArgument = pseudo.map { ", \(json($0))" } ?? ""
        let value = try eval(view, "[...document.querySelectorAll(\(json(selector)))].map(el => getComputedStyle(el\(pseudoArgument)).getPropertyValue(\(json(property))))")
        return try XCTUnwrap(value as? [String])
    }

    private func json(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), encoding: .utf8)!
    }

    private func markerSheets(_ view: WKWebView) throws -> Int {
        try XCTUnwrap(eval(view, "document.adoptedStyleSheets.filter(s => s.cssRules[0] && s.cssRules[0].selectorText === 'li[data-tarmac-marker]').length") as? Int)
    }

    private func assertControlMarked(_ view: WKWebView, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try marks(view, "#control > li"), ["disc", "disc"], "the control is marked", file: file, line: line)
    }

    func testS3NumberedItemsUseTheListItemCounter() throws {
        let view = try card("""
        <ol start=5><li>a</li><li>b</li></ol>
        <ol reversed><li>a</li><li>b</li><li>c</li></ol>
        <ol><li>a</li><li value=10>b</li><li>c</li></ol>
        <ol start=3 reversed><li>a</li><li>b</li></ol>
        """, zoom: 3)
        XCTAssertEqual(try marks(view, "ol > li"), Array(repeating: "decimal", count: 10))
        XCTAssertEqual(try style(view, "ol > li", "list-style-type"), Array(repeating: "none", count: 10))
        for content in try style(view, "ol > li", "content", pseudo: "::before") {
            XCTAssertTrue(content.contains("counter(list-item"), content)
            XCTAssertEqual(content.components(separatedBy: "counter(").count, 2, "one counter: \(content)")
        }
    }

    func testS4NestedBulletsAreDiscCircleSquare() throws {
        let view = try card("<ul><li id=a>a<ul><li id=b>b<ul><li id=c>c</li></ul></li></ul></li></ul>", zoom: 3)
        XCTAssertEqual(try [mark(view, "#a"), mark(view, "#b"), mark(view, "#c")], ["disc", "circle", "square"])
    }

    func testS5TypeAttributesGiveTheirMarkerTypes() throws {
        let view = try card("<ol type=I><li id=r>a</li></ol><ol type=a><li id=l>b</li></ol>", zoom: 3)
        XCTAssertEqual(try mark(view, "#r"), "upper-roman")
        XCTAssertEqual(try mark(view, "#l"), "lower-alpha")
        XCTAssertTrue(try style(view, "#r", "content", pseudo: "::before")[0].contains("upper-roman"))
        XCTAssertTrue(try style(view, "#l", "content", pseudo: "::before")[0].contains("lower-alpha"))
    }

    func testS6AListWithNoMarkerGetsNone() throws {
        let view = try card("<ul class=chips><li>a</li><li>b</li></ul>" + Self.control, css: "ul.chips { list-style: none; }", zoom: 3)
        XCTAssertEqual(try marks(view, ".chips > li"), [nil, nil])
        for content in try style(view, ".chips > li", "content", pseudo: "::before") {
            XCTAssertTrue(["none", "normal"].contains(content), content)
        }
        try assertControlMarked(view)
    }

    func testS7AnAuthorsSquareIsDrawnOnceByTarmac() throws {
        let view = try card("<ul class=sq><li>a</li><li>b</li></ul>", css: "ul.sq { list-style: square; }", zoom: 3)
        XCTAssertEqual(try marks(view, ".sq > li"), ["square", "square"])
        XCTAssertEqual(try style(view, ".sq > li", "list-style-type"), ["none", "none"])
    }

    func testS8AnAuthorsOwnBeforeContentIsLeftAlone() throws {
        let view = try card("<ul class=ticks><li>a</li></ul>" + Self.control, css: #"ul.ticks li::before { content: "✓ "; }"#, zoom: 3)
        XCTAssertEqual(try marks(view, ".ticks > li"), [nil])
        XCTAssertEqual(try style(view, ".ticks > li", "content", pseudo: "::before"), [#""✓ ""#])
        XCTAssertEqual(try style(view, ".ticks > li", "list-style-type"), ["disc"])
        try assertControlMarked(view)
    }

    func testS9MarkersTarmacCannotDrawKeepTheirNativeMarker() throws {
        let image = "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='4' height='4'/%3E\")"
        let cases: [(String, String)] = [
            ("string", #"list-style-type: "→ ""#),
            ("inside", "list-style-position: inside"),
            ("image", "list-style-image: \(image)"),
            ("rtl", "direction: rtl"),
            ("vertical", "writing-mode: vertical-rl"),
            ("hebrew", "list-style-type: hebrew"),
        ]
        let css = cases.map { "ul.\($0.0) { \($0.1); }" }.joined(separator: "\n") + "\nul.blocks > li { display: block; }"
        let body = cases.map { "<ul class=\($0.0)><li>a</li></ul>" }.joined()
            + "<ul class=blocks><li>a</li></ul><div id=div style='display:list-item'>d</div>" + Self.control
        let before = try card(body, css: css, zoom: 1)
        let view = try card(body, css: css, zoom: 3)
        for name in cases.map(\.0) + ["blocks"] {
            XCTAssertEqual(try marks(view, ".\(name) > li"), [nil], name)
            XCTAssertEqual(try style(view, ".\(name) > li", "list-style-type"), try style(before, ".\(name) > li", "list-style-type"), name)
        }
        XCTAssertNil(try mark(view, "#div"), "a list-item div")
        try assertControlMarked(view)
    }

    func testS10AnAuthorsStrongerImportantTypeKeepsTheNativeMarker() throws {
        let view = try card("<ul class=keep><li>a</li></ul>" + Self.control, css: "ul.keep > li { list-style-type: square !important; }", zoom: 3)
        XCTAssertEqual(try marks(view, ".keep > li"), [nil])
        XCTAssertEqual(try style(view, ".keep > li", "list-style-type"), ["square"])
        try assertControlMarked(view)
    }

    func testS17AnAuthorsWeakerImportantTypeIsDrawnOnceByTarmac() throws {
        let view = try card("<ul><li id=it>a</li></ul>", css: "li { list-style-type: square !important; }", zoom: 3)
        XCTAssertEqual(try mark(view, "#it"), "square")
        XCTAssertEqual(try style(view, "#it", "list-style-type"), ["none"])
    }

    func testS18AnAuthorsLaterBeforeContentWins() throws {
        let view = try card("<ul><li id=it>a</li></ul>", zoom: 3)
        _ = try eval(view, #"(document.head.appendChild(Object.assign(document.createElement('style'), { textContent: 'li::before { content: "– " }' })), 0)"#)
        XCTAssertEqual(try mark(view, "#it"), "disc")
        XCTAssertEqual(try style(view, "#it", "content", pseudo: "::before"), [#""– ""#])
    }

    func testS21AnAuthorsBeforeColourReachesTarmacsMarker() throws {
        let view = try card("<ul><li id=it>a</li></ul>", css: "li::before { color: rgb(200, 0, 0); }", zoom: 3)
        XCTAssertEqual(try mark(view, "#it"), "disc")
        XCTAssertEqual(try style(view, "#it", "color", pseudo: "::before"), ["rgb(200, 0, 0)"])
    }

    func testS23EverySupportedTypeIsMarkedAndDrawn() throws {
        // WebKit writes the default style out of a counter: `counter(list-item)`.
        let expected = ["disc": "•", "circle": "◦", "square": "▪", "decimal": "counter(list-item)"]
        let types = [
            "disc", "circle", "square", "decimal", "decimal-leading-zero", "lower-roman", "upper-roman",
            "lower-alpha", "upper-alpha", "lower-latin", "upper-latin", "lower-greek",
        ]
        let body = types.map { "<ol style='list-style-type:\($0)'><li id='t-\($0)'>a</li></ol>" }.joined()
        let view = try card(body, zoom: 3)
        for type in types {
            XCTAssertEqual(try mark(view, "#t-\(type)"), type)
            let content = try style(view, "#t-\(type)", "content", pseudo: "::before")[0]
            XCTAssertTrue(content.contains(expected[type] ?? type), "\(type): \(content)")
        }
    }

    // MARK: - When (D1, D5, D6)

    func testS11NoZoomOrAZoomOf1MarksNothing() throws {
        for zoom in [nil, 1.0] as [Double?] {
            let view = try card(Self.control, zoom: zoom)
            XCTAssertEqual(try marks(view, "li"), [nil, nil], "zoom \(String(describing: zoom))")
            XCTAssertEqual(try markerSheets(view), 0)
        }
    }

    func testS19APageWithNoItemGetsNoSheet() throws {
        let view = try card("<p>no list</p>", zoom: 3)
        XCTAssertEqual(try markerSheets(view), 0)
        XCTAssertEqual(try eval(view, "document.adoptedStyleSheets.length") as? Int, 0)
    }

    func testS12ItemsAddedAfterTheZoomAreMarkedBeforeTheNextTask() throws {
        let view = try card("<ul id=first><li>a</li></ul>", zoom: 3)
        _ = try eval(view, """
        (() => {
          const list = document.createElement('ul');
          list.id = 'added';
          list.innerHTML = '<li>x</li><li>y</li>';
          document.body.appendChild(list);
          document.getElementById('first').appendChild(document.createElement('li'));
          setTimeout(() => {
            window.seen = [...document.querySelectorAll('#added > li, #first > li:last-child')]
              .map(li => li.getAttribute('data-tarmac-marker'));
          }, 0);
          return 0;
        })()
        """)
        try spin(until: { (try? self.eval(view, "window.seen !== undefined")) as? Bool == true }, "the task")
        XCTAssertEqual(try eval(view, "window.seen") as? [String], ["disc", "disc", "disc"])
    }

    func testS13ASecondZoomAndALaterListKeepOneMarkAndOneSheet() throws {
        let view = try card("<ul id=first><li>a</li><li>b</li></ul>", zoom: 3)
        _ = try eval(view, "(document.body.insertAdjacentHTML('beforeend', '<ul id=second><li>c</li></ul>'), 0)")
        _ = try eval(view, "(window.postMessage({ tarmac: 'zoom', z: 3 }, '*'), 0)")
        _ = try eval(view, "(setTimeout(() => { window.done = true }, 0), 0)")
        try spin(until: { (try? self.eval(view, "window.done === true")) as? Bool == true }, "the second zoom")
        XCTAssertEqual(try marks(view, "#first > li"), ["disc", "disc"])
        XCTAssertEqual(try marks(view, "#second > li"), ["disc"])
        XCTAssertEqual(try markerSheets(view), 1)
    }

    func testS20TheFontSheetAndTheMarkerSheetBothStay() throws {
        let fonts = CardFontVariables(interfaceFamily: nil, documentFamily: nil, documentSize: 17)
        let view = try card(Self.control, zoom: 3, fonts: fonts)
        XCTAssertEqual(try eval(view, "document.adoptedStyleSheets.length") as? Int, 2)
        XCTAssertEqual(try markerSheets(view), 1)
        XCTAssertEqual(
            try eval(view, "getComputedStyle(document.documentElement).getPropertyValue('--tarmac-prose-size').trim()") as? String,
            "17px"
        )
        try assertControlMarked(view)
    }
}
