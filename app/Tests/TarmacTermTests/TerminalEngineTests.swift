import XCTest
@testable import TarmacTerm

@MainActor
final class TerminalEngineTests: XCTestCase {
    private func engine(cols: Int = 20, rows: Int = 4) throws -> TerminalEngine {
        try TerminalEngine(cols: cols, rows: rows)
    }

    private func feed(_ engine: TerminalEngine, _ text: String) {
        engine.feed(Array(text.utf8))
    }

    // MARK: screen

    func testFeedingPlainBytesShowsThemOnTheScreen() throws {
        let engine = try engine()
        feed(engine, "hello")
        XCTAssertEqual(engine.plainText(), "hello")
    }

    func testStyledOutputKeepsOnlyItsText() throws {
        let engine = try engine()
        feed(engine, "a\u{1b}[1;32mb\u{1b}[0mc\r\nd")
        XCTAssertEqual(engine.plainText(), "abc\nd")
    }

    func testResizeReflowsWrappedLines() throws {
        let engine = try engine(cols: 10, rows: 4)
        feed(engine, "0123456789abcde")
        XCTAssertEqual(engine.plainText(), "0123456789\nabcde")
        try engine.resize(cols: 15, rows: 4, cellWidthPx: 8, cellHeightPx: 16)
        XCTAssertEqual(engine.cols, 15)
        XCTAssertEqual(engine.plainText(), "0123456789abcde")
    }

    // MARK: effects

    func testDeviceAttributesQueryIsAnsweredToThePty() throws {
        let engine = try engine()
        var replies: [[UInt8]] = []
        engine.effects.onWritePty = { replies.append($0) }
        feed(engine, "\u{1b}[c")
        let reply = String(decoding: replies.joined(), as: UTF8.self)
        XCTAssertTrue(reply.hasPrefix("\u{1b}[?62;"), reply.debugDescription)
        XCTAssertTrue(reply.hasSuffix("c"), reply.debugDescription)
    }

    func testCursorPositionReportIsAnsweredToThePty() throws {
        let engine = try engine()
        var replies: [[UInt8]] = []
        engine.effects.onWritePty = { replies.append($0) }
        feed(engine, "ab\u{1b}[6n")
        XCTAssertEqual(String(decoding: replies.joined(), as: UTF8.self), "\u{1b}[1;3R")
    }

    func testBellRingsOncePerBel() throws {
        let engine = try engine()
        var bells = 0
        engine.effects.onBell = { bells += 1 }
        feed(engine, "a\u{07}b\u{07}")
        XCTAssertEqual(bells, 2)
    }

    func testOscTitleIsReadableAndAnnounced() throws {
        let engine = try engine()
        var changes = 0
        engine.effects.onTitleChanged = { changes += 1 }
        XCTAssertNil(engine.title)
        feed(engine, "\u{1b}]2;build ✓\u{07}")
        XCTAssertEqual(engine.title, "build ✓")
        XCTAssertEqual(changes, 1)
    }

    func testOsc7WorkingDirectoryIsReadable() throws {
        let engine = try engine()
        var changes = 0
        engine.effects.onWorkingDirectoryChanged = { changes += 1 }
        feed(engine, "\u{1b}]7;file://host/Users/me/src\u{07}")
        XCTAssertEqual(engine.workingDirectory, "file://host/Users/me/src")
        XCTAssertEqual(changes, 1)
    }

    /// With no host handler the write is denied, and the terminal must not
    /// claim clipboard support — a program's own copy key would look like it
    /// worked and copy nothing.
    func testClipboardIsNotAdvertisedUntilTheHostHandlesIt() throws {
        let engine = try engine()
        var replies: [[UInt8]] = []
        engine.effects.onWritePty = { replies.append($0) }
        feed(engine, "\u{1b}[c")
        XCTAssertEqual(String(decoding: replies.joined(), as: UTF8.self), "\u{1b}[?62;22c")

        replies = []
        engine.effects.onClipboardWrite = { _ in }
        feed(engine, "\u{1b}[c")
        XCTAssertEqual(String(decoding: replies.joined(), as: UTF8.self), "\u{1b}[?62;22;52c")
    }

    func testOsc52WriteReachesTheClipboardCallback() throws {
        let engine = try engine()
        var copied: [String] = []
        engine.effects.onClipboardWrite = { copied.append($0) }
        feed(engine, "\u{1b}]52;c;aGVsbG8=\u{07}")
        XCTAssertEqual(copied, ["hello"])
    }

    func testSynchronizedOutputAnnouncesItsHold() throws {
        let engine = try engine()
        var holds: [Bool] = []
        engine.effects.onRenderHold = { holds.append($0) }
        feed(engine, "\u{1b}[?2026hpartial")
        XCTAssertEqual(holds, [true])
        feed(engine, "\u{1b}[?2026l")
        XCTAssertEqual(holds, [true, false])
    }

    func testAnOverlongHoldCanBeEndedByTheHost() throws {
        let engine = try engine()
        feed(engine, "\u{1b}[?2026h")
        XCTAssertTrue(engine.isSynchronizedOutput)
        engine.endSynchronizedOutput()
        XCTAssertFalse(engine.isSynchronizedOutput)
    }

    func testCursorBlinksByDefault() throws {
        let engine = try engine()
        XCTAssertEqual(try FrameReader().read(engine).cursor?.blinks, true)
    }

    // MARK: modes

    func testModesFollowTheProgram() throws {
        let engine = try engine()
        XCTAssertFalse(engine.isMouseTracking)
        XCTAssertFalse(engine.isAlternateScreen)
        XCTAssertFalse(engine.isBracketedPaste)
        feed(engine, "\u{1b}[?1000h\u{1b}[?1049h\u{1b}[?2004h")
        XCTAssertTrue(engine.isMouseTracking)
        XCTAssertTrue(engine.isAlternateScreen)
        XCTAssertTrue(engine.isBracketedPaste)
    }

    // MARK: scrollback

    /// The row a dragged scroll thumb asks for. At the last row the viewport
    /// can start at, or past it, the viewport is the live one again and
    /// follows what is printed next.
    func test2610_0004S12AnAbsoluteRowIsWhereTheViewportStarts() throws {
        let engine = try engine(cols: 10, rows: 3)
        feed(engine, (1...10).map { "line\($0)" }.joined(separator: "\r\n"))
        XCTAssertEqual(engine.scrollbar, TerminalScrollbar(total: 10, offset: 7, visible: 3))

        engine.scrollViewport(.row(2))
        XCTAssertEqual(engine.scrollbar.offset, 2)
        XCTAssertFalse(engine.isViewportAtBottom)

        engine.scrollViewport(.row(7))
        XCTAssertEqual(engine.scrollbar.offset, 7)
        XCTAssertTrue(engine.isViewportAtBottom)
        feed(engine, "\r\nline11\r\nline12")
        XCTAssertEqual(engine.scrollbar, TerminalScrollbar(total: 12, offset: 9, visible: 3))

        engine.scrollViewport(.row(5))
        feed(engine, "\r\nline13")
        XCTAssertEqual(engine.scrollbar, TerminalScrollbar(total: 13, offset: 5, visible: 3))
        XCTAssertFalse(engine.isViewportAtBottom)

        engine.scrollViewport(.row(999))
        XCTAssertEqual(engine.scrollbar, TerminalScrollbar(total: 13, offset: 10, visible: 3))
        XCTAssertTrue(engine.isViewportAtBottom)
        feed(engine, "\r\nline14")
        XCTAssertEqual(engine.scrollbar, TerminalScrollbar(total: 14, offset: 11, visible: 3))

        engine.scrollViewport(.row(-4))
        XCTAssertEqual(engine.scrollbar.offset, 0)
    }

    func testViewportScrollsIntoHistoryAndBack() throws {
        let engine = try engine(cols: 10, rows: 3)
        feed(engine, (1...10).map { "line\($0)" }.joined(separator: "\r\n"))
        XCTAssertTrue(engine.isViewportAtBottom)
        XCTAssertEqual(engine.scrollbar, TerminalScrollbar(total: 10, offset: 7, visible: 3))

        engine.scrollViewport(.rows(-2))
        XCTAssertFalse(engine.isViewportAtBottom)
        XCTAssertEqual(engine.scrollbar.offset, 5)

        engine.scrollViewport(.top)
        XCTAssertEqual(engine.scrollbar.offset, 0)

        engine.scrollViewport(.bottom)
        XCTAssertTrue(engine.isViewportAtBottom)
    }

    /// 2610.0003 S27, a pin: a full-screen program has nothing to scroll, which
    /// is what keeps a scroll thumb off it. It guards a `GHOSTTY_COMMIT` bump.
    func test2610S27TheAlternateScreenReportsNoHistory() throws {
        let engine = try engine(cols: 10, rows: 3)
        feed(engine, (1...10).map { "line\($0)" }.joined(separator: "\r\n"))
        XCTAssertEqual(engine.scrollbar, TerminalScrollbar(total: 10, offset: 7, visible: 3))

        feed(engine, "\u{1b}[?1049h")
        XCTAssertEqual(engine.scrollbar, TerminalScrollbar(total: 3, offset: 0, visible: 3))

        feed(engine, "\u{1b}[?1049l")
        XCTAssertEqual(engine.scrollbar, TerminalScrollbar(total: 10, offset: 7, visible: 3))
    }

    func testScrollbackIsCappedNearItsLineLimit() throws {
        let engine = try engine(cols: 80, rows: 24)
        try engine.setScrollbackLimit(lines: 5000)
        feed(engine, (1...20000).map { "l\($0)" }.joined(separator: "\r\n"))
        // libghostty-vt prunes whole pages, so the cap lands within a page of the limit.
        XCTAssertLessThan(engine.scrollbar.total, 6000)
        XCTAssertGreaterThan(engine.scrollbar.total, 4000)
    }

    // MARK: tail

    func testTailIsTheLinesEndingAtTheCursor() throws {
        let engine = try engine(cols: 20, rows: 5)
        feed(engine, "one  \r\n\r\nthree")
        XCTAssertEqual(engine.tail(lines: 40), "one\n\nthree")
    }

    func testTailReachesBackIntoScrollback() throws {
        let engine = try engine(cols: 20, rows: 3)
        feed(engine, (1...50).map { "line\($0)" }.joined(separator: "\r\n"))
        XCTAssertEqual(engine.tail(lines: 4), "line47\nline48\nline49\nline50")
    }

    func testTailStopsAtTheCursorNotAtTheLastLine() throws {
        let engine = try engine(cols: 20, rows: 5)
        feed(engine, "a\r\nb\r\nc\u{1b}[A")
        XCTAssertEqual(engine.tail(lines: 40), "a\nb")
    }

    func testTailReportsRowsNotUnwrappedLines() throws {
        let engine = try engine(cols: 5, rows: 4)
        feed(engine, "abcdefgh")
        XCTAssertEqual(engine.tail(lines: 40), "abcde\nfgh")
    }

    func testTailIgnoresWhereTheViewportIsScrolled() throws {
        let engine = try engine(cols: 20, rows: 3)
        feed(engine, (1...50).map { "line\($0)" }.joined(separator: "\r\n"))
        engine.scrollViewport(.top)
        XCTAssertEqual(engine.tail(lines: 2), "line49\nline50")
    }

    // MARK: paste / focus

    func testPasteIsBracketedOnlyWhenTheProgramAskedForIt() throws {
        let engine = try engine()
        XCTAssertEqual(engine.encodePaste("a\nb"), Array("a\rb".utf8))
        feed(engine, "\u{1b}[?2004h")
        XCTAssertEqual(engine.encodePaste("a\nb"), Array("\u{1b}[200~a\nb\u{1b}[201~".utf8))
    }

    func testPasteStripsEscapeBytes() throws {
        let engine = try engine()
        feed(engine, "\u{1b}[?2004h")
        XCTAssertEqual(
            engine.encodePaste("x\u{1b}[201~y"),
            Array("\u{1b}[200~x [201~y\u{1b}[201~".utf8)
        )
    }

    func testFocusIsReportedOnlyWhenTheProgramAskedForIt() throws {
        let engine = try engine()
        XCTAssertEqual(engine.encodeFocus(gained: true), [])
        feed(engine, "\u{1b}[?1004h")
        XCTAssertEqual(engine.encodeFocus(gained: true), Array("\u{1b}[I".utf8))
        XCTAssertEqual(engine.encodeFocus(gained: false), Array("\u{1b}[O".utf8))
    }
}
