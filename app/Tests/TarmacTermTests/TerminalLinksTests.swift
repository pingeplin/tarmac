import XCTest
@testable import TarmacTerm

@MainActor
final class TerminalLinksTests: XCTestCase {
    private func row(_ output: String, cols: Int = 60) throws -> FrameRow {
        let engine = try TerminalEngine(cols: cols, rows: 2)
        engine.feed(Array(output.utf8))
        return try FrameReader().read(engine).rows[0]
    }

    /// Every URL on one row of output, left to right.
    private func urls(_ output: String) throws -> [TerminalLink] {
        let rows = [try row(output)]
        return rows[0].cells.indices.reduce(into: []) { found, col in
            let link = TerminalLinks.link(in: rows, atCol: col, row: 0, wraps: { _ in false })
            if let link, found.last != link { found.append(link) }
        }
    }

    func testAnHttpUrlIsFoundWithItsColumns() throws {
        let links = try urls("see https://example.com/a?b=1 now")
        XCTAssertEqual(links, [TerminalLink(url: "https://example.com/a?b=1", spans: [LinkSpan(row: 0, cols: 4...28)])])
    }

    func testTrailingPunctuationIsNotPartOfTheUrl() throws {
        XCTAssertEqual(try urls("(http://a.io/x).").map(\.url), ["http://a.io/x"])
        XCTAssertEqual(try urls("https://a.io/x, then").map(\.url), ["https://a.io/x"])
    }

    func testSeveralUrlsOnOneRowAreAllFound() throws {
        let links = try urls("http://a.io https://b.io")
        XCTAssertEqual(links.map(\.url), ["http://a.io", "https://b.io"])
        XCTAssertEqual(links.map(\.spans), [[LinkSpan(row: 0, cols: 0...10)], [LinkSpan(row: 0, cols: 12...23)]])
    }

    func testOtherSchemesAndBareHostsAreNotLinks() throws {
        XCTAssertEqual(try urls("file:///etc/passwd example.com mailto:a@b.c"), [])
    }

    func testColumnsAccountForWideCharactersBeforeTheUrl() throws {
        let links = try urls("世界 http://a.io")
        XCTAssertEqual(links, [TerminalLink(url: "http://a.io", spans: [LinkSpan(row: 0, cols: 5...15)])])
    }

    func testLinkAtAColumnIsLookedUp() throws {
        let line = [try row("see https://example.com now")]
        func url(atCol col: Int) -> String? {
            TerminalLinks.link(in: line, atCol: col, row: 0, wraps: { _ in false })?.url
        }
        XCTAssertEqual(url(atCol: 4), "https://example.com")
        XCTAssertEqual(url(atCol: 22), "https://example.com")
        XCTAssertNil(url(atCol: 3))
        XCTAssertNil(url(atCol: 23))
    }

    // MARK: wrapped lines

    private func screen(_ output: String, cols: Int) throws -> (rows: [FrameRow], engine: TerminalEngine) {
        let engine = try TerminalEngine(cols: cols, rows: 6)
        engine.feed(Array(output.utf8))
        return (try FrameReader().read(engine).rows, engine)
    }

    func testTheTerminalSaysWhichRowsItWrapped() throws {
        let (_, engine) = try screen("see https://example.com/a/long/path now\r\nnext", cols: 20)
        XCTAssertEqual((0..<3).map(engine.isSoftWrapped(row:)), [true, false, false])
    }

    func testAUrlTheTerminalWrappedIsReadAcrossItsRows() throws {
        let (rows, engine) = try screen("see https://example.com/a/long/path now", cols: 20)
        let whole = TerminalLink(
            url: "https://example.com/a/long/path",
            spans: [LinkSpan(row: 0, cols: 4...19), LinkSpan(row: 1, cols: 0...14)]
        )
        func link(atCol col: Int, row: Int) -> TerminalLink? {
            TerminalLinks.link(in: rows, atCol: col, row: row, wraps: engine.isSoftWrapped(row:))
        }
        XCTAssertEqual(link(atCol: 6, row: 0), whole)
        XCTAssertEqual(link(atCol: 3, row: 1), whole)
        XCTAssertNil(link(atCol: 3, row: 0))
        XCTAssertNil(link(atCol: 15, row: 1))
    }

    func testALinkFurtherDownTheScreenKeepsItsRows() throws {
        let (rows, engine) = try screen("one\r\ntwo\r\nsee https://example.com/a/long/path now", cols: 20)
        let link = TerminalLinks.link(in: rows, atCol: 3, row: 3, wraps: engine.isSoftWrapped(row:))
        XCTAssertEqual(link?.spans, [LinkSpan(row: 2, cols: 4...19), LinkSpan(row: 3, cols: 0...14)])
    }

    func testAUrlWrappedOverThreeRowsIsOneLink() throws {
        let (rows, engine) = try screen("https://example.com/aaaa/bbbb/cc", cols: 12)
        let link = TerminalLinks.link(in: rows, atCol: 5, row: 1, wraps: engine.isSoftWrapped(row:))
        XCTAssertEqual(link?.url, "https://example.com/aaaa/bbbb/cc")
        XCTAssertEqual(link?.spans, [
            LinkSpan(row: 0, cols: 0...11), LinkSpan(row: 1, cols: 0...11), LinkSpan(row: 2, cols: 0...7),
        ])
    }

    /// The program went to a new line itself with room left on the row, so
    /// the next row is not the URL going on.
    func testARowTheProgramEndedShortOfTheEdgeIsNotJoined() throws {
        let (rows, engine) = try screen("see https://example.com\r\n/a/long/path", cols: 30)
        func url(atCol col: Int, row: Int) -> String? {
            TerminalLinks.link(in: rows, atCol: col, row: row, wraps: engine.isSoftWrapped(row:))?.url
        }
        XCTAssertEqual(url(atCol: 6, row: 0), "https://example.com")
        XCTAssertNil(url(atCol: 3, row: 1))
    }

    func testAWideCharacterPushedToTheNextRowDoesNotBreakTheUrl() throws {
        let (rows, engine) = try screen("https://a.io/世界x", cols: 14)
        let link = TerminalLinks.link(in: rows, atCol: 0, row: 1, wraps: engine.isSoftWrapped(row:))
        XCTAssertEqual(link?.url, "https://a.io/世界x")
        XCTAssertEqual(link?.spans, [LinkSpan(row: 0, cols: 0...12), LinkSpan(row: 1, cols: 0...4)])
    }

    // MARK: rows a program broke itself

    /// Rows as Claude Code 2.1.289 drew them at 60 columns: it never lets the
    /// terminal wrap, and goes to the next row with CR and cursor-down.
    private func drawn(_ lines: [String]) throws -> (rows: [FrameRow], engine: TerminalEngine) {
        try screen(lines.joined(separator: "\r\u{1b}[1B"), cols: 60)
    }

    private func link(_ screen: (rows: [FrameRow], engine: TerminalEngine), atCol col: Int, row: Int) -> TerminalLink? {
        TerminalLinks.link(in: screen.rows, atCol: col, row: row, wraps: screen.engine.isSoftWrapped(row:))
    }

    private let longUrl = "https://example.com/tarmac-probe/seg01-alpha-bravo-charlie/seg02_delta_echo_foxtrot"
        + "/seg03golfhotelindiajuliet/seg04-kilo.lima.mike/seg05-november-oscar-papa/seg06_quebec_romeo_sierra"
        + "/seg07tangouniformvictor/seg08-whiskey-xray-yankee/end-marker"

    func testAUrlBrokenOverFullRowsIsOneLink() throws {
        let reply = try drawn([
            "⏺ Please see the page at https://example.com/tarmac-probe/se",
            "  g01-alpha-bravo-charlie/seg02_delta_echo_foxtrot/seg03golf",
            "  hotelindiajuliet/seg04-kilo.lima.mike/seg05-november-oscar",
            "  -papa/seg06_quebec_romeo_sierra/seg07tangouniformvictor/se",
            "  g08-whiskey-xray-yankee/end-marker for the full details",
        ])
        XCTAssertEqual((0..<5).map(reply.engine.isSoftWrapped(row:)), [false, false, false, false, false])
        let whole = TerminalLink(url: longUrl, spans: [
            LinkSpan(row: 0, cols: 25...59), LinkSpan(row: 1, cols: 2...59), LinkSpan(row: 2, cols: 2...59),
            LinkSpan(row: 3, cols: 2...59), LinkSpan(row: 4, cols: 2...35),
        ])
        XCTAssertEqual(link(reply, atCol: 30, row: 0), whole)
        XCTAssertEqual(link(reply, atCol: 10, row: 2), whole)
        XCTAssertEqual(link(reply, atCol: 5, row: 4), whole)
        XCTAssertNil(link(reply, atCol: 0, row: 1))
        XCTAssertNil(link(reply, atCol: 40, row: 4))
    }

    func testTheNextRowsIndentIsNotPartOfTheUrl() throws {
        let bullet = try drawn([
            "⏺ - Docs at https://example.com/tarmac-probe/seg01-alpha-bra",
            "    vo-charlie/seg02_delta_echo_foxtrot/seg03golfhotelindiaj",
            "    uliet/seg04-kilo.lima.mike/seg05-november-oscar-papa/seg",
            "    06_quebec_romeo_sierra/seg07tangouniformvictor/seg08-whi",
            "    skey-xray-yankee/end-marker now",
        ])
        XCTAssertEqual(link(bullet, atCol: 8, row: 3)?.url, longUrl)
        XCTAssertEqual(link(bullet, atCol: 8, row: 3)?.spans.map(\.cols.lowerBound), [12, 4, 4, 4, 4])

        let toolResult = try drawn([
            "  ⎿ \u{a0}https://example.com/tarmac-probe/seg01-alpha-bravo-char",
            "     lie/seg02_delta_echo_foxtrot/seg03golfhotelindiajuliet/",
            "     seg04-kilo.lima.mike/seg05-november-oscar-papa/seg06_qu",
            "     ebec_romeo_sierra/seg07tangouniformvictor/seg08-whiskey",
            "     -xray-yankee/end-marker",
        ])
        XCTAssertEqual(link(toolResult, atCol: 9, row: 4)?.url, longUrl)
    }

    func testWhatClosesTheBrokenUrlIsLeftOut() throws {
        let toolCall = try drawn([
            "⏺ Bash(echo https://example.com/tarmac-probe/seg01-alpha-bra",
            "  vo-charlie/seg02_delta_echo_foxtrot/seg03golfhotelindiajul",
            "  iet/seg04-kilo.lima.mike/seg05-november-oscar-papa/seg06_q",
            "  uebec_romeo_sierra/seg07tangouniformvictor/seg08-whiskey-x",
            "  ray-yankee/end-marker)",
        ])
        XCTAssertEqual(link(toolCall, atCol: 20, row: 0)?.url, longUrl)
        XCTAssertEqual(link(toolCall, atCol: 22, row: 4)?.spans.last, LinkSpan(row: 4, cols: 2...22))
        XCTAssertNil(link(toolCall, atCol: 23, row: 4))
    }

    func testABreakInsideTheSchemeStillReadsAsOneUrl() throws {
        let reply = try drawn([
            "⏺ Please see the page that I found for you earlier, at: http",
            "  s://example.com/tarmac-probe/seg01-alpha-bravo-charlie/seg",
            "  02 and more.",
        ])
        let url = "https://example.com/tarmac-probe/seg01-alpha-bravo-charlie/seg02"
        XCTAssertEqual(link(reply, atCol: 57, row: 0)?.url, url)
        XCTAssertEqual(link(reply, atCol: 3, row: 2)?.url, url)
    }

    func testTwoWordsThatFitOnARowTogetherWereNotOneWordBroken() throws {
        let url = "https://example.com/" + String(repeating: "a", count: 30)
        let reply = try drawn(["  abcdefg " + url, "  12345678 and more"])
        XCTAssertEqual(link(reply, atCol: 20, row: 0)?.url, url)
        XCTAssertNil(link(reply, atCol: 4, row: 1))
    }

    /// A row holds less than the terminal is wide: the next row's indent
    /// comes off it. A wide character takes two of its columns.
    func testAWordOneColumnTooLongForItsRowWasBroken() throws {
        let narrow = "https://example.com/" + String(repeating: "a", count: 39)
        let broken = try drawn(["  " + narrow.dropLast(), "  a"])
        XCTAssertEqual(link(broken, atCol: 2, row: 1)?.url, narrow)

        let wide = "https://example.com/" + String(repeating: "界", count: 19) + "a"
        let brokenWide = try drawn(["  " + wide.dropLast(), "  a"])
        XCTAssertEqual(link(brokenWide, atCol: 2, row: 1)?.url, wide)
    }

    func testAWideCharacterAtTheEdgeFillsTheRow() throws {
        let reply = try drawn([
            "  https://example.com/tarmac-probe/seg01-alpha-bravo-char/世",
            "  界/seg02_delta_echo_foxtrot now",
        ])
        let url = "https://example.com/tarmac-probe/seg01-alpha-bravo-char/世界/seg02_delta_echo_foxtrot"
        XCTAssertEqual(link(reply, atCol: 10, row: 0)?.url, url)
        XCTAssertEqual(link(reply, atCol: 8, row: 1)?.url, url)
    }

    /// A word that fits on a row is never split, so a URL that ends at the
    /// edge with room for the next row's word beside it was not broken there.
    func testAUrlThatMerelyEndsAtTheEdgeTakesNothingFromTheNextRow() throws {
        let reply = try drawn([
            "⏺ First red green blue yellow https://example.com/docs/guide",
            "  then some more ordinary words follow right here.",
        ])
        XCTAssertEqual(link(reply, atCol: 40, row: 0), TerminalLink(
            url: "https://example.com/docs/guide", spans: [LinkSpan(row: 0, cols: 30...59)]
        ))
        XCTAssertNil(link(reply, atCol: 3, row: 1))
    }

    func testAFullRowThatEndsInAnotherWordIsNotJoined() throws {
        let reply = try drawn([
            "  https://example.com/fits-on-one-row/abcdefghijz and then a",
            "  few more ordinary words to finish.",
        ])
        XCTAssertEqual(link(reply, atCol: 10, row: 0)?.url, "https://example.com/fits-on-one-row/abcdefghijz")
        XCTAssertNil(link(reply, atCol: 3, row: 1))
    }

    func testAUrlOnTheNextRowIsItsOwn() throws {
        let list = try drawn([
            "  https://example.com/a-url-that-is-exactly-as-wide-as-row/x",
            "  https://example.com/second",
        ])
        XCTAssertEqual(link(list, atCol: 10, row: 0)?.url, "https://example.com/a-url-that-is-exactly-as-wide-as-row/x")
        XCTAssertEqual(link(list, atCol: 10, row: 1)?.url, "https://example.com/second")
    }

    /// The echo of the prompt stops a column short of the edge, where a row
    /// that merely ended there looks the same: it is left alone.
    func testARowThatStopsShortOfTheEdgeIsNotJoined() throws {
        let echo = try drawn([
            "  https://example.com/tarmac-probe/seg01-alpha-bravo-charli",
            "  e/seg02_delta_echo_foxtrot/seg03golfhotelindiajuliet/seg0",
        ])
        XCTAssertEqual(link(echo, atCol: 10, row: 0)?.url, "https://example.com/tarmac-probe/seg01-alpha-bravo-charli")
        XCTAssertNil(link(echo, atCol: 10, row: 1))
    }

    func testOsc8HyperlinkIsReadFromTheTerminal() throws {
        let engine = try TerminalEngine(cols: 40, rows: 2)
        engine.feed(Array("go \u{1b}]8;;https://example.com/doc\u{1b}\\here\u{1b}]8;;\u{1b}\\ end".utf8))
        XCTAssertEqual(engine.hyperlink(col: 4, row: 0), "https://example.com/doc")
        XCTAssertNil(engine.hyperlink(col: 0, row: 0))
        XCTAssertNil(engine.hyperlink(col: 9, row: 0))
    }
}
