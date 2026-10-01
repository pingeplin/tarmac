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

    func testOsc52WriteReachesTheClipboardCallback() throws {
        let engine = try engine()
        var copied: [String] = []
        engine.effects.onClipboardWrite = { copied.append($0) }
        feed(engine, "\u{1b}]52;c;aGVsbG8=\u{07}")
        XCTAssertEqual(copied, ["hello"])
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
