import WebKit
import XCTest
@testable import TarmacKit

/// The width cap on media in an HTML card (spec 2611.0020), checked in real
/// WebKit on a `CardPage`. Every page also holds the control, an SVG the
/// author sized `width: 100%`, which the cap holds to 560×140: a page whose
/// cap is missing fails on it, whatever its own medium does.
@MainActor
final class CardMediaCapTests: XCTestCase {
    private struct Medium {
        let id: String
        let body: String
        var css = ""
    }

    private static let prelude = """
    function box(id) {
      const z = parseFloat(document.documentElement.style.zoom) || 1;
      const r = document.getElementById(id).getBoundingClientRect();
      return [r.left / z, r.top / z, r.width / z, r.height / z];
    }
    function isMediaSheet(s) {
      return !!(s.cssRules[0] && s.cssRules[0].style && s.cssRules[0].style.objectFit === 'contain');
    }
    function mediaSheet() {
      return document.adoptedStyleSheets.find(isMediaSheet);
    }
    """

    /// A PNG black but for its right tenth, which is red.
    private static func png(_ width: Int, _ height: Int) -> String {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        )!
        let bytes = rep.bitmapData!
        for y in 0..<height {
            for x in 0..<width {
                let at = (y * width + x) * 4
                bytes[at] = x * 10 >= width * 9 ? 255 : 0
                bytes[at + 1] = 0
                bytes[at + 2] = 0
                bytes[at + 3] = 255
            }
        }
        return "data:image/png;base64," + rep.representation(using: .png, properties: [:])!.base64EncodedString()
    }

    private static let wide = png(2000, 500)
    private static let small = png(24, 24)

    /// An SVG drawing `width`×`height` user units, black but for its right
    /// tenth, which is red.
    private static func svg(_ id: String, _ attributes: String, width: Int = 1000, height: Int = 250, inner: String = "") -> String {
        let red = width * 9 / 10
        return """
        <svg id="\(id)" \(attributes)><rect width="\(red)" height="\(height)"/>\
        <rect x="\(red)" width="\(width - red)" height="\(height)" fill="red"/>\(inner)</svg>
        """
    }

    private static let control = svg("control", #"viewBox="0 0 1000 250" style="width:100%""#)

    private static let s1 = Medium(id: "m", body: #"<img id="m" src="\#(wide)">"#)
    private static let s2 = Medium(id: "m", body: #"<img id="m" width="1200" height="300" src="\#(wide)">"#)
    private static let s3 = Medium(id: "m", body: svg("m", #"viewBox="0 0 1000 250""#), css: "svg { width: 100%; }")
    private static let s4 = Medium(id: "m", body: svg("m", #"width="1000" height="250" viewBox="0 0 1000 250""#))
    private static let s5 = Medium(id: "m", body: svg("m", #"width="1000" height="250""#))
    private static let s6 = Medium(
        id: "m",
        body: svg("m", #"viewBox="0 0 1000 250""#, inner: svg("inner", #"x="0" y="0" width="1000" height="250" viewBox="0 0 1000 250""#)),
        css: "svg { width: 100%; }"
    )
    private static let s7 = Medium(id: "m", body: """
    <canvas id="m" width="1200" height="200" style="width:1200px;height:200px"></canvas>
    <script>
      const pen = document.getElementById('m').getContext('2d');
      pen.beginPath(); pen.arc(600, 100, 90, 0, 2 * Math.PI); pen.fill();
    </script>
    """)
    private static let s8 = Medium(id: "m", body: #"<img id="m" style="height:200px" src="\#(wide)">"#)
    private static let s9 = Medium(id: "m", body: #"<video id="m" width="1200" height="300"></video>"#)
    private static let s10 = Medium(id: "m", body: #"<div style="width:200px"><img id="m" src="\#(wide)"></div>"#)
    private static let s11 = [
        Medium(id: "cell", body: #"<table><tr><td><img id="cell" src="\#(wide)"></td></tr></table>"#),
        Medium(id: "flex", body: #"<div style="display:flex"><img id="flex" src="\#(wide)"></div>"#),
        Medium(id: "inline", body: #"<div style="display:inline-block"><img id="inline" src="\#(wide)"></div>"#),
    ]
    private static let s12 = [
        Medium(id: "icon", body: #"<img id="icon" src="\#(small)">"#),
        Medium(id: "glyph", body: svg("glyph", #"viewBox="0 0 16 16" width="16" height="16""#, width: 16, height: 16)),
    ]
    private static let s21 = Medium(id: "m", body: #"<img id="m" width="400" height="400" src="\#(wide)">"#)
    private static let s22 = [
        Medium(id: "tall", body: svg("tall", #"viewBox="0 0 1000 100" height="200""#, height: 100)),
        Medium(id: "square", body: svg("square", #"viewBox="0 0 100 100" width="300" height="100""#, width: 100, height: 100)),
    ]
    private static let s23 = Medium(id: "m", body: """
    <div id="scroller" style="width:600px;overflow:auto">\(svg("m", #"width="1000" height="250" viewBox="0 0 1000 250""#))</div>
    """)
    private static let s24 = Medium(id: "m", body: #"<canvas id="m" width="1200" height="300"></canvas>"#)

    private func card(
        _ body: String, css: String = "", head: String = "", zoom: Double? = nil, fonts: CardFontVariables? = nil
    ) throws -> WKWebView {
        let page = """
        <!doctype html><script>\(try CardPage.shim(fonts: fonts))</script><html><head><meta charset="utf-8">\(head)<style>
        html { background: #fff } body { margin: 0; width: 1000px }
        \(css)
        </style></head><body>\(body)<div>\(Self.control)</div></body></html>
        """
        return try CardPage.load(page, zoom: zoom)
    }

    private func card(_ medium: Medium, css: String = "", head: String = "", zoom: Double? = nil) throws -> WKWebView {
        try card(medium.body, css: medium.css + "\n" + css, head: head, zoom: zoom)
    }

    private func eval(_ view: WKWebView, _ script: String) throws -> Any? {
        try CardPage.eval(view, script, prelude: Self.prelude)
    }

    /// Left, top, width and height in card px.
    private func box(_ view: WKWebView, _ id: String) throws -> [Double] {
        try XCTUnwrap(eval(view, "box(\(json(id)))") as? [Double], id)
    }

    private func json(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), encoding: .utf8)!
    }

    private func assertBox(
        _ view: WKWebView, _ id: String, _ width: Double, _ height: Double, _ what: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let b = try box(view, id)
        XCTAssertEqual(b[2], width, accuracy: 1, "\(what) \(id) width", file: file, line: line)
        XCTAssertEqual(b[3], height, accuracy: 1, "\(what) \(id) height", file: file, line: line)
    }

    private func assertControl(_ view: WKWebView, file: StaticString = #filePath, line: UInt = #line) throws {
        try assertBox(view, "control", 560, 140, "the control", file: file, line: line)
    }

    // MARK: - Pixels, at no zoom

    private struct Shot {
        let rep: NSBitmapImageRep
        let scale: Double

        func color(_ x: Double, _ y: Double) -> NSColor? {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
        }

        func isRed(_ x: Double, _ y: Double) -> Bool {
            guard let c = color(x, y) else { return false }
            return c.redComponent > 0.7 && c.greenComponent < 0.3 && c.blueComponent < 0.3
        }

        func isWhite(_ x: Double, _ y: Double) -> Bool {
            guard let c = color(x, y) else { return false }
            return min(c.redComponent, c.greenComponent, c.blueComponent) > 0.9
        }

        /// The length, in view points, from the first to the last pixel that
        /// is not white along a row (`y`) or a column (`x`) of `range`.
        func inked(row y: Double, from: Double, to: Double) -> Double {
            let hits = stride(from: Int(from * scale), to: Int(to * scale), by: 1).filter { !isWhite(Double($0) / scale, y) }
            return hits.isEmpty ? 0 : Double(hits.last! - hits.first! + 1) / scale
        }

        func inked(column x: Double, from: Double, to: Double) -> Double {
            let hits = stride(from: Int(from * scale), to: Int(to * scale), by: 1).filter { !isWhite(x, Double($0) / scale) }
            return hits.isEmpty ? 0 : Double(hits.last! - hits.first! + 1) / scale
        }
    }

    private func shot(_ view: WKWebView) throws -> Shot {
        let rep = try CardPage.snapshot(view)
        return Shot(rep: rep, scale: Double(rep.pixelsWide) / Double(view.bounds.width))
    }

    private func assertRedAtRightEdge(_ view: WKWebView, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let b = try box(view, id)
        XCTAssertTrue(try shot(view).isRed(b[0] + b[2] - 5, b[1] + b[3] / 2), "\(id): red at its right edge", file: file, line: line)
    }

    // MARK: - The cap (G1, G2)

    func testS1AWideImageIsCappedAt560InEveryZoom() throws {
        for zoom in [nil, 1, 3] as [Double?] {
            let view = try card(Self.s1, zoom: zoom)
            try assertBox(view, "m", 560, 140, "zoom \(String(describing: zoom))")
            try assertControl(view)
            if zoom == nil { try assertRedAtRightEdge(view, "m") }
        }
    }

    func testS2AnImageSizedByItsAttributesKeepsItsRatio() throws {
        let view = try card(Self.s2)
        try assertBox(view, "m", 560, 140)
        try assertControl(view)
    }

    func testS3AnSVGTheAuthorSizedFullWidthIsCappedAndScaled() throws {
        let view = try card(Self.s3)
        try assertBox(view, "m", 560, 140)
        try assertControl(view)
        try assertRedAtRightEdge(view, "m")
    }

    func testS4AnSVGWithAViewBoxAndASizeIsCapped() throws {
        let view = try card(Self.s4)
        try assertBox(view, "m", 560, 140)
        try assertControl(view)
    }

    func testS5AnSVGWithNoViewBoxKeepsItsSizeAndIsNotCropped() throws {
        let view = try card(Self.s5)
        try assertBox(view, "m", 1000, 250)
        try assertControl(view)
        try assertRedAtRightEdge(view, "m")
    }

    func testS6ANestedSVGScalesWithItsParent() throws {
        let view = try card(Self.s6)
        let outer = try box(view, "m")
        XCTAssertEqual(outer[2], 560, accuracy: 1, "the outer svg")
        XCTAssertEqual(try box(view, "inner")[2], outer[2], accuracy: 1, "the nested svg")
        try assertControl(view)
    }

    func testS7ACanvasWithAFixedHeightDrawsUndistorted() throws {
        let view = try card(Self.s7)
        try assertBox(view, "m", 560, 200)
        try assertControl(view)
        let b = try box(view, "m")
        let shot = try shot(view)
        let width = shot.inked(row: b[1] + b[3] / 2, from: b[0], to: b[0] + b[2])
        let height = shot.inked(column: b[0] + b[2] / 2, from: b[1], to: b[1] + b[3])
        XCTAssertGreaterThan(width, 0, "the circle is drawn")
        XCTAssertEqual(width, height, accuracy: 2, "the circle is round")
    }

    func testS8AnImageWithAFixedHeightDrawsWholeAndUndistortedInItsBox() throws {
        let view = try card(Self.s8)
        try assertBox(view, "m", 560, 200)
        try assertControl(view)
        let b = try box(view, "m")
        let (midX, midY) = (b[0] + b[2] / 2, b[1] + b[3] / 2)
        let shot = try shot(view)
        XCTAssertEqual(shot.inked(row: midY, from: b[0], to: b[0] + b[2]), 560, accuracy: 2, "drawn width")
        XCTAssertEqual(shot.inked(column: midX, from: b[1], to: b[1] + b[3]), 140, accuracy: 2, "drawn height")
        XCTAssertTrue(shot.isWhite(midX, b[1] + 5), "the band above")
        XCTAssertTrue(shot.isWhite(midX, b[1] + b[3] - 5), "the band below")
        XCTAssertTrue(shot.isRed(b[0] + b[2] - 5, midY), "red at its right edge")
    }

    func testS9AVideoSizedByItsAttributesIsCapped() throws {
        let view = try card(Self.s9)
        try assertBox(view, "m", 560, 140)
        try assertControl(view)
    }

    func testS10AnImageInANarrowBoxIsNoWiderThanTheBox() throws {
        let view = try card(Self.s10)
        try assertBox(view, "m", 200, 50)
        try assertControl(view)
    }

    func testS11AnImageInACellAFlexRowOrAnInlineBlockDoesNotCollapse() throws {
        let view = try card(Self.s11.map(\.body).joined())
        for medium in Self.s11 { try assertBox(view, medium.id, 560, 140) }
        try assertControl(view)
    }

    func testS12SmallMediaKeepTheirSize() throws {
        let view = try card(Self.s12.map(\.body).joined())
        try assertBox(view, "icon", 24, 24)
        try assertBox(view, "glyph", 16, 16)
        try assertControl(view)
    }

    // MARK: - The author's rules win (G3)

    func testS13AnAuthorsMaxWidthLiftsTheCap() throws {
        let pages: [(String, String, Double, Double)] = [
            ("img { max-width: none; }", #"<img id="m" src="\#(Self.wide)">"#, 2000, 500),
            (".w { max-width: 100%; }", #"<img id="m" class="w" src="\#(Self.wide)">"#, 1000, 250),
            ("", #"<img id="m" style="max-width:none" src="\#(Self.wide)">"#, 2000, 500),
        ]
        for (css, body, width, height) in pages {
            let view = try card(body, css: css)
            try assertBox(view, "m", width, height, body)
            try assertControl(view)
        }
    }

    func testS14AnAuthorsOwnCapWins() throws {
        let view = try card(Self.s1, css: "img { max-width: 300px; }")
        try assertBox(view, "m", 300, 75)
        try assertControl(view)
    }

    func testS15AnAuthorsObjectFitWins() throws {
        let view = try card(Self.s8, css: "img { object-fit: cover; }")
        XCTAssertEqual(try eval(view, "getComputedStyle(document.getElementById('m')).objectFit") as? String, "cover")
        try assertControl(view)
    }

    // MARK: - When (D4, D5)

    func testS16ARevealCardIsCappedToo() throws {
        let view = try card(Self.s1, head: #"<meta name="tarmac-zoom" content="reveal">"#)
        try assertBox(view, "m", 560, 140)
        try assertControl(view)
        try assertRedAtRightEdge(view, "m")
    }

    func testS17TheCapIsThereBeforeTheBodyIsParsed() throws {
        let probe = """
        <script>
          window.seenMaxWidth = (() => {
            const img = document.createElement('img');
            document.documentElement.appendChild(img);
            const value = getComputedStyle(img).maxWidth;
            img.remove();
            return value;
          })();
        </script>
        """
        let view = try card("", head: probe)
        let seen = try XCTUnwrap(eval(view, "window.seenMaxWidth") as? String)
        XCTAssertNotEqual(seen, "none")
        try assertControl(view)
    }

    func testS18OneMediaSheetFirstBesideTheFontAndMarkerSheets() throws {
        let fonts = CardFontVariables(interfaceFamily: "Menlo", documentFamily: "Georgia", documentSize: 16)
        let later = CardFontVariables(interfaceFamily: nil, documentFamily: nil, documentSize: 20)
        let view = try card("<ul><li>a</li></ul>", zoom: 3, fonts: fonts)
        let fontSheet = "document.adoptedStyleSheets.find(s => s.cssRules[0] && s.cssRules[0].selectorText === ':root')"
        _ = try eval(view, "(window.postMessage({ tarmac: 'fonts', vars: \(later.json) }, '*'), 0)")
        try CardPage.spin(
            until: { (try? self.eval(view, "\(fontSheet).cssRules[0].style.getPropertyValue('--tarmac-prose-size')")) as? String == "20px" },
            "the second fonts message"
        )
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(later.json.utf8)) as? [String: String])
        for (name, value) in expected {
            XCTAssertEqual(try eval(view, "\(fontSheet).cssRules[0].style.getPropertyValue(\(json(name))).trim()") as? String, value, name)
        }
        XCTAssertEqual(try eval(view, "document.adoptedStyleSheets.filter(isMediaSheet).length") as? Int, 1, "one media sheet")
        XCTAssertEqual(try eval(view, "document.adoptedStyleSheets.indexOf(mediaSheet())") as? Int, 0, "the media sheet first")
        XCTAssertEqual(
            try eval(view, "document.adoptedStyleSheets.filter(s => s.cssRules[0] && s.cssRules[0].selectorText === 'li[data-tarmac-marker]').length") as? Int,
            1, "one marker sheet"
        )
        XCTAssertEqual(
            try eval(view, "document.styleSheets[document.styleSheets.length - 1].cssRules[0].selectorText") as? String,
            "li[data-tarmac-marker]", "the marker sheet last"
        )
        try assertControl(view)
    }

    // MARK: - height: auto with a width attribute only (D1a, G5)

    func testS21AWidthAttributeGivesTheImageItsOwnRatio() throws {
        let view = try card(Self.s21)
        try assertBox(view, "m", 400, 100)
        try assertControl(view)
    }

    func testS22AnSVGKeepsTheHeightItWasGiven() throws {
        let view = try card(Self.s22.map(\.body).joined())
        try assertBox(view, "tall", 560, 200)
        try assertBox(view, "square", 300, 100)
        try assertControl(view)
    }

    func testS23AnSVGInAnAuthorsScrollerIsCappedAndTheScrollerNoLongerScrolls() throws {
        let view = try card(Self.s23)
        try assertBox(view, "m", 560, 140)
        let scroller = try XCTUnwrap(eval(view, "[document.getElementById('scroller').scrollWidth, document.getElementById('scroller').clientWidth]") as? [Double])
        XCTAssertEqual(scroller[0], scroller[1], "scrollWidth against clientWidth")
        try assertControl(view)
    }

    func testS24ACanvasSizedByItsAttributesIsCapped() throws {
        let view = try card(Self.s24)
        try assertBox(view, "m", 560, 140)
        try assertControl(view)
    }

    func testS25TheCapNeverMakesAMediumLarger() throws {
        let short = Medium(id: "m", body: #"<img id="m" height="40" src="\#(Self.wide)">"#)
        let sparkline = Self.svg("m", #"viewBox="0 0 100 20" height="20""#, width: 100, height: 20)
        let inline = Medium(id: "m", body: #"<span style="display:inline-block">\#(sparkline)</span>"#)
        let alone = Medium(id: "m", body: sparkline)
        let video = Medium(id: "m", body: #"<video id="m" height="40"></video>"#)
        let exact: [(Medium, Double, Double)] = [(short, 160, 40), (inline, 100, 20), (alone, 100, 20), (video, 80, 40)]
        let media = [Self.s1, Self.s2, Self.s3, Self.s4, Self.s5, Self.s6, Self.s7, Self.s8, Self.s9, Self.s10]
            + Self.s11 + Self.s12 + [Self.s21] + Self.s22 + [Self.s23, Self.s24]
        for (medium, width, height) in exact.map({ ($0.0, Optional($0.1), Optional($0.2)) }) + media.map({ ($0, nil, nil) }) {
            let view = try card(medium)
            try assertControl(view)
            let on = try box(view, medium.id)
            XCTAssertEqual(try eval(view, "(mediaSheet().disabled = true, document.body.offsetWidth, true)") as? Bool, true, "the sheet is off")
            let off = try box(view, medium.id)
            XCTAssertLessThanOrEqual(on[2], off[2] + 1, "\(medium.body) width")
            XCTAssertLessThanOrEqual(on[3], off[3] + 1, "\(medium.body) height")
            if let width, let height {
                XCTAssertEqual(on[2], width, accuracy: 1, "\(medium.body) width")
                XCTAssertEqual(on[3], height, accuracy: 1, "\(medium.body) height")
            }
        }
    }
}
