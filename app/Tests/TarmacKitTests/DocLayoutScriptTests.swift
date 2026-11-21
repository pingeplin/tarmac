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
        return (["| \(header) |", "|" + String(repeating: "---|", count: columns)] + rows).joined(separator: "\n") + "\n"
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
        let width = try XCTUnwrap(context.evaluateScript("""
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
        let html = try render("- item\n\n  " + table("n | d", "| 1 | \(a(40)) |").replacingOccurrences(of: "\n|", with: "\n  |"))

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
}
