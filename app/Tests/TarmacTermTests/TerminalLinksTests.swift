import XCTest
@testable import TarmacTerm

@MainActor
final class TerminalLinksTests: XCTestCase {
    private func row(_ output: String, cols: Int = 60) throws -> FrameRow {
        let engine = try TerminalEngine(cols: cols, rows: 2)
        engine.feed(Array(output.utf8))
        return try FrameReader().read(engine).rows[0]
    }

    func testAnHttpUrlIsFoundWithItsColumns() throws {
        let links = TerminalLinks.urls(in: try row("see https://example.com/a?b=1 now"))
        XCTAssertEqual(links, [RowLink(cols: 4...28, url: "https://example.com/a?b=1")])
    }

    func testTrailingPunctuationIsNotPartOfTheUrl() throws {
        XCTAssertEqual(TerminalLinks.urls(in: try row("(http://a.io/x).")).map(\.url), ["http://a.io/x"])
        XCTAssertEqual(TerminalLinks.urls(in: try row("https://a.io/x, then")).map(\.url), ["https://a.io/x"])
    }

    func testSeveralUrlsOnOneRowAreAllFound() throws {
        let links = TerminalLinks.urls(in: try row("http://a.io https://b.io"))
        XCTAssertEqual(links.map(\.url), ["http://a.io", "https://b.io"])
        XCTAssertEqual(links.map(\.cols), [0...10, 12...23])
    }

    func testOtherSchemesAndBareHostsAreNotLinks() throws {
        XCTAssertEqual(TerminalLinks.urls(in: try row("file:///etc/passwd example.com mailto:a@b.c")), [])
    }

    func testColumnsAccountForWideCharactersBeforeTheUrl() throws {
        let links = TerminalLinks.urls(in: try row("世界 http://a.io"))
        XCTAssertEqual(links, [RowLink(cols: 5...15, url: "http://a.io")])
    }

    func testLinkAtAColumnIsLookedUp() throws {
        let line = try row("see https://example.com now")
        XCTAssertEqual(TerminalLinks.url(in: line, atCol: 4), "https://example.com")
        XCTAssertEqual(TerminalLinks.url(in: line, atCol: 22), "https://example.com")
        XCTAssertNil(TerminalLinks.url(in: line, atCol: 3))
        XCTAssertNil(TerminalLinks.url(in: line, atCol: 23))
    }

    func testOsc8HyperlinkIsReadFromTheTerminal() throws {
        let engine = try TerminalEngine(cols: 40, rows: 2)
        engine.feed(Array("go \u{1b}]8;;https://example.com/doc\u{1b}\\here\u{1b}]8;;\u{1b}\\ end".utf8))
        XCTAssertEqual(engine.hyperlink(col: 4, row: 0), "https://example.com/doc")
        XCTAssertNil(engine.hyperlink(col: 0, row: 0))
        XCTAssertNil(engine.hyperlink(col: 9, row: 0))
    }
}
