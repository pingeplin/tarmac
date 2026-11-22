import JavaScriptCore
import XCTest

/// The doc card's table markup as it ships (spec 2611.0021): the bundled
/// `marked.umd.js` and `doc-layout.js`, run in that order in a bare
/// `JSContext`, markdown in and HTML out.
final class DocLayoutScriptTests: XCTestCase {
    private func page() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail("the script threw: \(String(describing: error))") }
        context.evaluateScript(try AppSource.text("Resources/Web/marked.umd.js"))
        context.evaluateScript(try AppSource.text("Resources/Web/doc-layout.js"))
        return context
    }

    private func evaluate(_ script: String, markdown: String) throws -> String {
        let context = try page()
        context.setObject(markdown, forKeyedSubscript: "md" as NSString)
        return try XCTUnwrap(context.evaluateScript(script)?.toString())
    }

    private func render(_ markdown: String) throws -> String {
        try evaluate("tarmacDocLayout.render(md)", markdown: markdown)
    }

    private func markedParse(_ markdown: String) throws -> String {
        try evaluate("marked.parse(md)", markdown: markdown)
    }

    private func textColumns(_ markdown: String) throws -> [Bool] {
        let json = try evaluate("JSON.stringify(tarmacDocLayout.textColumns(marked.lexer(md)[0]))", markdown: markdown)
        return try JSONDecoder().decode([Bool].self, from: Data(json.utf8))
    }

    private func a(_ count: Int) -> String { String(repeating: "a", count: count) }

    private func table(_ header: String, _ rows: String...) -> String {
        let columns = header.split(separator: "|").count
        return (["| \(header) |", "|" + String(repeating: "---|", count: columns)] + rows).joined(separator: "\n")
            + "\n"
    }

    private func occurrences(of part: String, in text: String) -> Int {
        text.components(separatedBy: part).count - 1
    }

    /// S26
    func testS26TheScriptsLoadWithNoDOM() throws {
        let context = try page()
        XCTAssertEqual(context.evaluateScript("typeof tarmacDocLayout.render")?.toString(), "function")
        XCTAssertEqual(context.evaluateScript("typeof tarmacDocLayout.textColumns")?.toString(), "function")
    }

    /// S8
    func testS8AColumnWithAProseCellOfFortyIsATextColumn() throws {
        XCTAssertEqual(try textColumns(table("n | d", "| 1 | \(a(40)) |", "| 2 | ok |")), [false, true])
    }

    /// S9
    func testS9ThirtyNineIsNot() throws {
        XCTAssertEqual(try textColumns(table("n | d", "| 1 | \(a(39)) |")), [false, false])
    }

    /// S10
    func testS10InlineCodeDoesNotCount() throws {
        XCTAssertEqual(try textColumns(table("d", "| `\(a(60))` hello |")), [false])
        XCTAssertEqual(try textColumns(table("d", "| \(a(20)) `x` \(a(20)) |")), [true])
        XCTAssertEqual(try textColumns(table("d", "| **\(a(40))** |")), [true])
    }

    /// S11
    func testS11TheProseIsTrimmed() throws {
        XCTAssertEqual(try textColumns(table("d", "| \(a(39)) `x` |")), [false])
    }

    /// S12
    func testS12AShortRowCountsItsMissingCellsAsEmpty() throws {
        XCTAssertEqual(
            try textColumns(table("x | y | z", "| x | y | \(a(40)) |", "| \(a(40)) |")), [true, false, true]
        )
    }

    /// S13
    func testS13AWideCharacterCountsTwoAndWidthIsByCodePoint() throws {
        func column(_ cell: String) throws -> [Bool] { try textColumns(table("d", "| \(cell) |")) }
        XCTAssertEqual(try column(String(repeating: "字", count: 20)), [true])
        XCTAssertEqual(try column(String(repeating: "字", count: 19)), [false])
        XCTAssertEqual(try column(String(repeating: "😀", count: 20)), [true])
        XCTAssertEqual(try column(String(repeating: "\u{e9}", count: 39)), [false])
        XCTAssertEqual(try column(String(repeating: "\u{1D400}", count: 39)), [false])
    }

    /// S13 — the first and the last code point of every wide range count 2;
    /// U+10FF, before the first range, and U+1F650, after one, count 1.
    func testS13EveryWideRangeIsWideToItsEdges() throws {
        let ranges: [(UInt32, UInt32)] = [
            (0x1100, 0x115F), (0x2E80, 0x303E), (0x3041, 0x33FF), (0x3400, 0x4DBF), (0x4E00, 0x9FFF),
            (0xA000, 0xA4CF), (0xAC00, 0xD7A3), (0xF900, 0xFAFF), (0xFE30, 0xFE4F), (0xFF00, 0xFF60),
            (0xFFE0, 0xFFE6), (0x1F300, 0x1F64F), (0x1F900, 0x1F9FF), (0x20000, 0x3FFFD),
        ]
        let context = try page()
        let width = try XCTUnwrap(
            context.evaluateScript(
                """
                (point) => tarmacDocLayout.textColumns(marked.lexer("| d |\\n|---|\\n| " +
                  String.fromCodePoint(point).repeat(20) + " |\\n")[0])[0]
                """))
        for (low, high) in ranges {
            XCTAssertEqual(width.call(withArguments: [low]).toBool(), true, String(low, radix: 16))
            XCTAssertEqual(width.call(withArguments: [high]).toBool(), true, String(high, radix: 16))
        }
        XCTAssertEqual(width.call(withArguments: [0x10FF]).toBool(), false)
        XCTAssertEqual(width.call(withArguments: [0x1F650]).toBool(), false)
    }

    /// S38 — an escaped character is prose.
    func testS38AnEscapeCountsAsProse() throws {
        XCTAssertEqual(try textColumns(table("d", "| \(a(38))\\*\\* |")), [true])
        XCTAssertEqual(try textColumns(table("d", "| \(a(37))\\*\\* |")), [false])
    }

    /// S14
    func testS14AHeaderOnlyTableHasNoTextColumn() throws {
        let markdown = "| \(a(50)) | b |\n|---|---|\n"
        XCTAssertEqual(try textColumns(markdown), [false, false])
        XCTAssertFalse(try render(markdown).contains("doc-text-col"))
    }

    /// S33
    func testS33EveryMarkdownTableIsWrappedAndTheRestIsMarkedsOwn() throws {
        let markdown = "Some *text*\nhere.\n\n" + table("a | b", "| 1 | 2 |") + "\n- item\n\n  " + table("c", "| 3 |")
        let html = try render(markdown)

        XCTAssertEqual(occurrences(of: "<div class=\"doc-table\"><table>", in: html), 2)
        XCTAssertEqual(occurrences(of: "</table>", in: html), 2)
        let closed = try NSRegularExpression(pattern: #"</table>\s*</div>"#)
        XCTAssertEqual(closed.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html)), 2)
        XCTAssertTrue(html.hasPrefix(try markedParse("Some *text*\nhere.")))
    }

    /// S34
    func testS34EveryCellOfATextColumnHasTheClass() throws {
        let html = try render(table("n | d", "| 1 | \(a(40)) |", "| 2 | ok |"))

        XCTAssertTrue(html.contains("<th class=\"doc-text-col\">d</th>"))
        XCTAssertEqual(occurrences(of: "<td class=\"doc-text-col\">", in: html), 2)
        XCTAssertEqual(occurrences(of: "class=", in: html), 4)
    }

    /// S34 — a table inside a list item is marked too.
    func testS34ANestedTableMarksItsTextColumn() throws {
        let html = try render(
            "- item\n\n  " + table("n | d", "| 1 | \(a(40)) |").replacingOccurrences(of: "\n|", with: "\n  |"))

        XCTAssertEqual(occurrences(of: "<div class=\"doc-table\"><table>", in: html), 1)
        XCTAssertTrue(html.contains("<th class=\"doc-text-col\">d</th>"))
        XCTAssertTrue(html.contains("<td class=\"doc-text-col\">"))
    }

    /// S35
    func testS35AlignmentIsKeptAndARawTableIsUntouched() throws {
        let aligned = try render("| d | n |\n|:-:|--:|\n| \(a(40)) | 1 |\n")
        XCTAssertTrue(aligned.contains("<th align=\"center\" class=\"doc-text-col\">"))
        XCTAssertTrue(aligned.contains("<td align=\"right\">1</td>"))

        let raw = "<table><tr><td>x</td></tr></table>\n"
        XCTAssertEqual(try render(raw), try markedParse(raw))
    }

    /// S36
    func testS36TheGlobalMarkedIsUntouched() throws {
        let markdown = table("n | d", "| 1 | \(a(40)) |")
        let html = try evaluate("tarmacDocLayout.render(md); marked.parse(md)", markdown: markdown)

        XCTAssertFalse(html.contains("doc-table"))
        XCTAssertFalse(html.contains("doc-text-col"))
    }

    // 2611.0022: the outline and the sidebar's page rules.

    private func json(_ expression: String, markdown: String = "") throws -> String {
        try evaluate("JSON.stringify(\(expression))", markdown: markdown)
    }

    private func outline(_ markdown: String) throws -> String {
        try json("tarmacDocLayout.parse(md, '').outline", markdown: markdown)
    }

    private func headingText(_ markdown: String) throws -> String {
        try evaluate("tarmacDocLayout.parse(md, '').outline[0].text", markdown: markdown)
    }

    private let outlined = "# A\n\ntext\n\n## B\n\n#### D\n\n- item\n\n  ### C\n\nSet\n---\n"

    /// 2611.0022 S24
    func test2611_0022S24TheOutlineIsEveryHeadingToDepthThreeNestedOnesToo() throws {
        XCTAssertEqual(
            try outline(outlined),
            #"[{"depth":1,"text":"A"},{"depth":2,"text":"B"},{"depth":3,"text":"C"},{"depth":2,"text":"Set"}]"#
        )
        XCTAssertEqual(try outline("> ### Q\n\n# R"), #"[{"depth":3,"text":"Q"},{"depth":1,"text":"R"}]"#)
    }

    /// 2611.0022 S25
    func test2611_0022S25AHeadingsTextIsItsPlainText() throws {
        XCTAssertEqual(try headingText("## The `code` *and* **marks**"), "The code and marks")
        XCTAssertEqual(try headingText("## [Link](u) \\* <b>x</b>  y"), "Link * x y")
        XCTAssertEqual(try headingText("## Tom &amp; Jerry &#x41;"), "Tom & Jerry A")
        XCTAssertEqual(try headingText("## `a &amp; b`"), "a &amp; b")
        XCTAssertEqual(try headingText("## ![alt](u) x"), "x")
        XCTAssertEqual(try headingText("## a &lt; b &gt; &quot;c&quot; &#39;d&#39; &#65;"), "a < b > \"c\" 'd' A")
        XCTAssertEqual(try headingText("a\\\nb\n==="), "a b")
        XCTAssertEqual(try headingText("## x &#x110000; y"), "x &#x110000; y")
        XCTAssertEqual(try headingText("## a &amp;lt; b"), "a &lt; b")
    }

    /// 2611.0022 S26
    func test2611_0022S26AnOutlinedHeadingCarriesTheRendersMark() throws {
        let html = try evaluate("tarmacDocLayout.parse(md, 'k9').html", markdown: outlined)
        let headings = [
            "<h1 data-outline=\"k9-0\">A</h1>", "<h2 data-outline=\"k9-1\">B</h2>",
            "<h3 data-outline=\"k9-2\">C</h3>", "<h2 data-outline=\"k9-3\">Set</h2>",
        ]
        let places = try headings.map { try XCTUnwrap(html.range(of: $0), $0).lowerBound }
        XCTAssertEqual(places, places.sorted())
        XCTAssertEqual(occurrences(of: "data-outline", in: html), 4)

        let unmarked = try evaluate("tarmacDocLayout.parse(md, '').html", markdown: outlined)
        XCTAssertFalse(unmarked.contains("data-outline"))
        XCTAssertEqual(
            unmarked, html.replacingOccurrences(of: #" data-outline="k9-\d""#, with: "", options: .regularExpression))
        XCTAssertEqual(try render(outlined), unmarked)
    }

    /// 2611.0022 S26 — a render keeps no outline and no mark from the one
    /// before it.
    func test2611_0022S26ARenderStartsAFreshOutlineAndMark() throws {
        let context = try page()
        context.setObject(outlined, forKeyedSubscript: "md" as NSString)
        context.evaluateScript("tarmacDocLayout.parse(md, 'k9'); var second = tarmacDocLayout.parse('# R', '');")

        XCTAssertEqual(
            context.evaluateScript("JSON.stringify(second.outline)")?.toString(), #"[{"depth":1,"text":"R"}]"#)
        XCTAssertEqual(context.evaluateScript("second.html.indexOf('data-outline')")?.toInt32(), -1)
    }

    /// 2611.0022 S27
    func test2611_0022S27ARawHTMLHeadingIsNotInTheOutline() throws {
        let markdown = "<h2>raw</h2>\n\n## md"
        XCTAssertEqual(try outline(markdown), #"[{"depth":2,"text":"md"}]"#)
        XCTAssertTrue(try evaluate("tarmacDocLayout.parse(md, 'k9').html", markdown: markdown).contains("<h2>raw</h2>"))
    }

    /// 2611.0022 S28
    func test2611_0022S28TheCurrentSection() throws {
        let context = try page()
        func current(_ tops: [Double], _ scrollTop: Double, _ view: Double, _ height: Double, _ zoom: Double) -> Int32?
        {
            context.evaluateScript("tarmacDocLayout.currentSection")?
                .call(withArguments: [tops, scrollTop, view, height, zoom]).toInt32()
        }
        for (scrollTop, index) in [(0.0, 0), (475, 0), (476, 1), (1175, 1), (1176, 2)] as [(Double, Int32)] {
            XCTAssertEqual(current([0, 500, 1200], scrollTop, 400, 3000, 1), index, "\(scrollTop)")
        }
        XCTAssertEqual(current([0, 500, 1200], 487, 400, 3000, 0.5), 0)
        XCTAssertEqual(current([0, 500, 1200], 488, 400, 3000, 0.5), 1)
        XCTAssertEqual(current([37, 500], 0, 400, 3000, 1), 0)
        XCTAssertEqual(current([0, 500, 2900], 2598, 400, 3000, 1), 1)
        XCTAssertEqual(current([0, 500, 2900], 2599, 400, 3000, 1), 2)
        XCTAssertEqual(current([37, 200, 300], 0, 400, 400, 1), 0)
        XCTAssertEqual(current([0, 200, 390], 1, 400, 401, 1), 0)
        XCTAssertEqual(current([], 0, 400, 3000, 1), -1)
    }

    /// 2611.0022 D11l: a heading the render did not mark has no top and is never current.
    func test2611_0022AnUnmarkedHeadingIsNeverCurrent() throws {
        func current(_ tops: String, _ scrollTop: Int, _ height: Int) throws -> String {
            try json("tarmacDocLayout.currentSection(\(tops), \(scrollTop), 400, \(height), 1)")
        }
        XCTAssertEqual(try current("[null, 500, null, 1200]", 0, 3000), "1")
        XCTAssertEqual(try current("[null, 500, null, 1200]", 1176, 3000), "3")
        XCTAssertEqual(try current("[0, 500, null]", 2600, 3000), "1")
        XCTAssertEqual(try current("[null, null]", 0, 3000), "-1")
        XCTAssertEqual(try json("tarmacDocLayout.scrollTarget(null, 400, 3000, 1)"), "null")
    }

    /// 2611.0022 S29
    func test2611_0022S29TheDragWidth() throws {
        func drag(_ arguments: String) throws -> String { try json("tarmacDocLayout.dragWidth(\(arguments))") }
        XCTAssertEqual(try drag("240, 30, 0.5, 1, 160, 420"), #"{"width":300,"collapsed":false}"#)
        XCTAssertEqual(try drag("240, 30, 1, -1, 160, 420"), #"{"width":210,"collapsed":false}"#)
        XCTAssertEqual(try drag("240, 400, 1, 1, 160, 420"), #"{"width":420,"collapsed":false}"#)
        XCTAssertEqual(try drag("240, -81, 1, 1, 160, 420"), #"{"width":159,"collapsed":true}"#)
        XCTAssertEqual(try drag("240, -80, 1, 1, 160, 420"), #"{"width":160,"collapsed":false}"#)
        XCTAssertEqual(try drag("240, -300, 1, 1, 160, 420"), #"{"width":-60,"collapsed":true}"#)
        XCTAssertEqual(try drag("200, 100, 1, 1, 160, 240"), #"{"width":240,"collapsed":false}"#)
    }

    /// 2611.0022 S29a
    func test2611_0022S29aNoContentShowsNoSidebar() throws {
        XCTAssertEqual(try evaluate("tarmacDocLayout.shownMode({mode: 'docked'}, 0, 0)", markdown: ""), "none")
        XCTAssertEqual(try evaluate("tarmacDocLayout.shownMode({mode: 'docked'}, 1, 0)", markdown: ""), "docked")
        XCTAssertEqual(try evaluate("tarmacDocLayout.shownMode({mode: 'docked'}, 0, 2)", markdown: ""), "docked")
        XCTAssertEqual(try evaluate("tarmacDocLayout.shownMode(null, 1, 2)", markdown: ""), "none")
    }

    /// 2611.0022 S29b
    func test2611_0022S29bTheGeometryOfEachMode() throws {
        func geometry(_ mode: String, _ width: Double = 240, drag: String = "null") throws -> String {
            try json("tarmacDocLayout.geometry({mode: '\(mode)', width: \(width), strip: 30, grip: 8}, 1280, \(drag))")
        }
        func box(_ text: Double, _ offset: Double, _ panel: Double) -> String {
            #"{"textWidth":\#(Int(text)),"offset":\#(Int(offset)),"panel":\#(Int(panel))}"#
        }
        XCTAssertEqual(try geometry("none"), box(1280, 0, 0))
        XCTAssertEqual(try geometry("strip"), box(1250, 30, 0))
        XCTAssertEqual(try geometry("docked"), box(1032, 248, 240))
        XCTAssertEqual(try geometry("overlay"), box(1250, 30, 240))
        XCTAssertEqual(try geometry("docked", drag: "{width: 300, collapsed: false}"), box(972, 308, 300))
        XCTAssertEqual(try geometry("docked", drag: "{width: -60, collapsed: true}"), box(1250, 30, 0))
        XCTAssertEqual(try geometry("overlay", drag: "{width: 200, collapsed: false}"), box(1250, 30, 200))
        XCTAssertEqual(try geometry("overlay", drag: "{width: 100, collapsed: true}"), box(1250, 30, 0))
        XCTAssertEqual(
            try json("tarmacDocLayout.geometry({mode: 'docked', width: 240, strip: 20, grip: 10}, 1280, null)"),
            box(1030, 250, 240)
        )
        XCTAssertEqual(
            try json("tarmacDocLayout.geometry({mode: 'overlay', width: 240, strip: 20, grip: 10}, 1280, null)"),
            box(1260, 20, 240)
        )
        XCTAssertEqual(
            try json(
                """
                tarmacDocLayout.geometry(Object.assign({}, state, {mode: tarmacDocLayout.shownMode(state, 0, 0)}), 1280, null)
                """.replacingOccurrences(of: "state", with: "{mode: 'docked', width: 240, strip: 30, grip: 8}")),
            box(1280, 0, 0)
        )
    }

    /// 2611.0022 S29c
    func test2611_0022S29cTheReleaseReport() throws {
        XCTAssertEqual(try json("tarmacDocLayout.release(false, {width: 300, collapsed: false})"), "null")
        XCTAssertEqual(
            try json("tarmacDocLayout.release(true, {width: 300, collapsed: false})"),
            #"{"action":"resize","width":300}"#
        )
        XCTAssertEqual(try json("tarmacDocLayout.release(true, {width: -60, collapsed: true})"), #"{"action":"close"}"#)
    }

    /// 2611.0022 S29d
    func test2611_0022S29dTheStripsIconsAndTicks() throws {
        let outline = "[1, 2, 3, 2, 3].map(function (depth) { return {depth: depth, text: 'h'}; })"
        func strip(_ fields: Int, _ outline: String, _ current: Int) throws -> String {
            try json("tarmacDocLayout.strip(\(fields), \(outline), \(current))")
        }
        XCTAssertEqual(
            try strip(2, outline, 2), #"{"icons":["fields","outline"],"ticks":[0,1,3],"lit":1,"section":"fields"}"#)
        XCTAssertEqual(try json("tarmacDocLayout.strip(2, \(outline), 4).lit"), "3")
        XCTAssertEqual(try json("tarmacDocLayout.strip(2, \(outline), -1).lit"), "-1")
        XCTAssertEqual(try json("tarmacDocLayout.strip(2, \(outline), 1).lit"), "1")
        XCTAssertEqual(try json("tarmacDocLayout.strip(2, \(outline), 3).lit"), "3")
        XCTAssertEqual(try json("tarmacDocLayout.strip(0, \(outline), 2).icons"), #"["outline"]"#)
        XCTAssertEqual(try json("tarmacDocLayout.strip(0, \(outline), 2).section"), #""outline""#)
        XCTAssertEqual(try strip(1, "[]", -1), #"{"icons":["fields"],"ticks":[],"lit":-1,"section":"fields"}"#)
        XCTAssertEqual(try strip(0, "[]", -1), #"{"icons":[],"ticks":[],"lit":-1,"section":null}"#)
    }

    /// 2611.0022 S29e
    func test2611_0022S29eAnIconClick() throws {
        func click(_ arguments: String) throws -> String { try json("tarmacDocLayout.iconClick(\(arguments))") }
        XCTAssertEqual(
            try click("'strip', 'fields', 'outline'"), #"{"post":"open","section":"outline","scroll":"onOpen"}"#)
        XCTAssertEqual(
            try click("'overlay', 'outline', 'outline'"), #"{"post":"close","section":"outline","scroll":null}"#)
        XCTAssertEqual(try click("'overlay', 'outline', 'fields'"), #"{"post":null,"section":"fields","scroll":"now"}"#)
        XCTAssertEqual(try click("'docked', 'outline', 'fields'"), #"{"post":null,"section":"outline","scroll":null}"#)
    }

    /// 2611.0022 S29f
    func test2611_0022S29fTheScrollTarget() throws {
        for (arguments, target) in [
            ("500, 400, 3000, 1", "492"), ("500, 400, 3000, 0.5", "496"), ("4, 400, 3000, 1", "0"),
            ("2900, 400, 3000, 1", "2600"), ("10, 400, 300, 1", "0"),
        ] {
            XCTAssertEqual(try json("tarmacDocLayout.scrollTarget(\(arguments))"), target, arguments)
        }
    }

    /// 2611.0022 D11g, 2611.0025 S8: what of the sidebar shows and where the
    /// panel starts, from the sidebar's outer edge.
    func test2611_0022TheSidebarsParts() throws {
        func parts(_ mode: String, panel: Int, resizable: Bool = true) throws -> String {
            let state = "{strip: 30, grip: 8, resizable: \(resizable)}"
            return try json("tarmacDocLayout.parts('\(mode)', {panel: \(panel)}, \(state))")
        }
        func box(_ strip: Bool, _ panel: Bool, _ start: Int, _ grip: Bool) -> String {
            #"{"strip":\#(strip),"panel":\#(panel),"panelStart":\#(start),"grip":\#(grip)}"#
        }
        XCTAssertEqual(try parts("none", panel: 0), box(false, false, 0, false))
        XCTAssertEqual(try parts("strip", panel: 0), box(true, false, 0, false))
        XCTAssertEqual(try parts("docked", panel: 240), box(false, true, 0, true))
        XCTAssertEqual(try parts("docked", panel: 0), box(true, false, 0, false))
        XCTAssertEqual(try parts("overlay", panel: 240), box(true, true, 30, true))
        XCTAssertEqual(try parts("overlay", panel: 0), box(true, false, 30, false))
        XCTAssertEqual(try parts("overlay", panel: 150, resizable: false), box(true, true, 30, false))
    }

    /// 2611.0022 D11h: a press on the text closes an overlay and nothing else.
    func test2611_0022APressOnTheTextClosesAnOverlay() throws {
        XCTAssertEqual(try json("tarmacDocLayout.pressOnText('overlay')"), #""close""#)
        for mode in ["none", "strip", "docked"] {
            XCTAssertEqual(try json("tarmacDocLayout.pressOnText('\(mode)')"), "null", mode)
        }
    }

    /// 2611.0022 D11i: what a drag's end reports and which width the page
    /// keeps until the app's answer; a press with no move, or a pointer back at
    /// its start, has not moved, even over a width kept from the last drag.
    func test2611_0022ADragsEnd() throws {
        let width = "{width: 300, collapsed: false}"
        XCTAssertEqual(try json("tarmacDocLayout.dragEnd(false, 0, null)"), #"{"report":null,"drag":null}"#)
        XCTAssertEqual(try json("tarmacDocLayout.dragEnd(true, 0, \(width))"), #"{"report":null,"drag":null}"#)
        XCTAssertEqual(try json("tarmacDocLayout.dragEnd(false, 12, \(width))"), #"{"report":null,"drag":null}"#)
        XCTAssertEqual(
            try json("tarmacDocLayout.dragEnd(true, 12, \(width))"),
            #"{"report":{"action":"resize","width":300},"drag":{"width":300,"collapsed":false}}"#
        )
        XCTAssertEqual(
            try json("tarmacDocLayout.dragEnd(true, -200, {width: -60, collapsed: true})"),
            #"{"report":{"action":"close"},"drag":{"width":-60,"collapsed":true}}"#
        )
    }

    /// 2611.0022 D11i: only the app's answer to an action ends a kept drag
    /// width; a layout (a zoom, a card resize) keeps it, and a held drag goes on.
    func test2611_0022WhatEndsAKeptDrag() throws {
        let width = "{width: 300, collapsed: false}"
        XCTAssertEqual(try json("tarmacDocLayout.dragOnState(false, \(width), true)"), "null")
        XCTAssertEqual(
            try json("tarmacDocLayout.dragOnState(false, \(width), false)"), #"{"width":300,"collapsed":false}"#)
        XCTAssertEqual(
            try json("tarmacDocLayout.dragOnState(true, \(width), true)"), #"{"width":300,"collapsed":false}"#)
        XCTAssertEqual(
            try json("tarmacDocLayout.dragOnState(true, \(width), false)"), #"{"width":300,"collapsed":false}"#)
    }

    /// 2611.0022 D11: the drag's direction is the sidebar's side.
    func test2611_0022TheDragDirectionIsTheSide() throws {
        XCTAssertEqual(try json("tarmacDocLayout.direction('left')"), "1")
        XCTAssertEqual(try json("tarmacDocLayout.direction('right')"), "-1")
    }

    /// 2611.0022 D11j: an open asked for shows its section once a state shows
    /// the panel; any state ends the wait.
    func test2611_0022ASectionWaitsForTheOpen() throws {
        XCTAssertEqual(try json("tarmacDocLayout.sectionOnState(true, true)"), "true")
        XCTAssertEqual(try json("tarmacDocLayout.sectionOnState(true, false)"), "false")
        XCTAssertEqual(try json("tarmacDocLayout.sectionOnState(false, true)"), "false")
    }

    /// 2611.0022 D11k: the strip icon of the section an overlay shows is marked.
    func test2611_0022TheActiveIcon() throws {
        XCTAssertEqual(try json("tarmacDocLayout.activeIcon('overlay', 'fields')"), #""fields""#)
        XCTAssertEqual(try json("tarmacDocLayout.activeIcon('strip', 'fields')"), "null")
        XCTAssertEqual(try json("tarmacDocLayout.activeIcon('docked', 'outline')"), "null")
    }

    /// 2611.0022 D11d: the lit tick on its own, so a scroll need not rebuild the strip.
    func test2611_0022TheLitTick() throws {
        for (current, lit) in [(-1, "-1"), (0, "0"), (1, "1"), (2, "1"), (3, "3"), (4, "3")] {
            XCTAssertEqual(try json("tarmacDocLayout.lit([0, 1, 3], \(current))"), lit, "\(current)")
        }
        XCTAssertEqual(try json("tarmacDocLayout.lit([], 2)"), "-1")
    }

    /// 2611.0022 D16: a move that leaves the drag's width as it was lays nothing out again.
    func test2611_0022AnUnchangedDragIsNotLaidOutAgain() throws {
        let width = "{width: 300, collapsed: false}"
        XCTAssertEqual(try json("tarmacDocLayout.sameDrag(\(width), {width: 300, collapsed: false})"), "true")
        XCTAssertEqual(try json("tarmacDocLayout.sameDrag(\(width), {width: 301, collapsed: false})"), "false")
        XCTAssertEqual(try json("tarmacDocLayout.sameDrag(\(width), {width: 300, collapsed: true})"), "false")
        XCTAssertEqual(try json("tarmacDocLayout.sameDrag(null, \(width))"), "false")
    }

    /// 2611.0025 S7: the side the page lays its sidebar out on; anything but
    /// exactly "right" is the left.
    func test2611_0025S7ThePagesSide() throws {
        XCTAssertEqual(try json("tarmacDocLayout.side({side: 'right'})"), #""right""#)
        XCTAssertEqual(try json("tarmacDocLayout.direction(tarmacDocLayout.side({side: 'right'}))"), "-1")
        for state in ["{side: 'left'}", "{}", "{side: 'Right'}", "{side: 1}", "null"] {
            XCTAssertEqual(try json("tarmacDocLayout.side(\(state))"), #""left""#, state)
        }
        XCTAssertEqual(
            try json("tarmacDocLayout.dragWidth(240, -60, 1, -1, 160, 420)"), #"{"width":300,"collapsed":false}"#)
        XCTAssertEqual(
            try json("tarmacDocLayout.dragWidth(240, 81, 1, -1, 160, 420)"), #"{"width":159,"collapsed":true}"#)
    }
}
