import JavaScriptCore
import XCTest

/// The doc card's table markup as it ships (spec 2611.0021): the bundled
/// `marked.umd.js` and `doc-layout.js`, run in that order in a bare
/// `JSContext`, markdown in and HTML out.
final class DocLayoutScriptTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: app.appendingPathComponent("Sources/TarmacApp/Resources/Web/\(name)"), encoding: .utf8
        )
    }

    private func page() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail("the script threw: \(String(describing: error))") }
        context.evaluateScript(try source("marked.umd.js"))
        context.evaluateScript(try source("doc-layout.js"))
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

    /// S14
    func testS14AHeaderOnlyTableHasNoTextColumn() throws {
        let markdown = "| \(a(50)) | b |\n|---|---|\n"
        XCTAssertEqual(try textColumns(markdown), [false, false])
        XCTAssertFalse(try render(markdown).contains("doc-text-col"))
    }

    /// S33
    func testS33EveryMarkdownTableIsWrappedAndTheRestIsMarkedsOwn() throws {
        let markdown = "Some *text* here.\n\n" + table("a | b", "| 1 | 2 |") + "\n- item\n\n  " + table("c", "| 3 |")
        let html = try render(markdown)

        XCTAssertEqual(occurrences(of: "<div class=\"doc-table\"><table>", in: html), 2)
        XCTAssertEqual(occurrences(of: "</table>", in: html), 2)
        let closed = try NSRegularExpression(pattern: #"</table>\s*</div>"#)
        XCTAssertEqual(closed.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html)), 2)
        XCTAssertTrue(html.hasPrefix(try markedParse("Some *text* here.")))
    }

    /// S34
    func testS34EveryCellOfATextColumnHasTheClass() throws {
        let html = try render(table("n | d", "| 1 | \(a(40)) |", "| 2 | ok |"))

        XCTAssertTrue(html.contains("<th class=\"doc-text-col\">d</th>"))
        XCTAssertEqual(occurrences(of: "<td class=\"doc-text-col\">", in: html), 2)
        XCTAssertEqual(occurrences(of: "class=", in: html), 4)
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
