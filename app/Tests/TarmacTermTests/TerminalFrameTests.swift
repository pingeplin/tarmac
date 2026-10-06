import XCTest
@testable import TarmacTerm

@MainActor
final class TerminalFrameTests: XCTestCase {
    private func make(cols: Int = 12, rows: Int = 3) throws -> (TerminalEngine, FrameReader) {
        (try TerminalEngine(cols: cols, rows: rows), try FrameReader())
    }

    private func feed(_ engine: TerminalEngine, _ text: String) {
        engine.feed(Array(text.utf8))
    }

    func testFrameCarriesTheGridAndItsText() throws {
        let (engine, reader) = try make()
        feed(engine, "hi")
        let frame = reader.read(engine)
        XCTAssertEqual(frame.cols, 12)
        XCTAssertEqual(frame.rows.count, 3)
        XCTAssertEqual(frame.rows[0].cells.count, 12)
        XCTAssertEqual(frame.rows[0].cells[0].text, "h")
        XCTAssertEqual(frame.rows[0].cells[1].text, "i")
        XCTAssertEqual(frame.rows[0].cells[2].text, "")
        XCTAssertEqual(frame.rows[0].text, "hi")
    }

    func testCursorFollowsTheOutput() throws {
        let (engine, reader) = try make()
        feed(engine, "hi\r\nx")
        let cursor = try XCTUnwrap(reader.read(engine).cursor)
        XCTAssertEqual(cursor.col, 1)
        XCTAssertEqual(cursor.row, 1)
        XCTAssertEqual(cursor.shape, .block)
    }

    func testHiddenCursorIsAbsent() throws {
        let (engine, reader) = try make()
        feed(engine, "\u{1b}[?25l")
        XCTAssertNil(reader.read(engine).cursor)
    }

    func testCursorShapeFollowsDecscusr() throws {
        let (engine, reader) = try make()
        feed(engine, "\u{1b}[6 q")
        XCTAssertEqual(reader.read(engine).cursor?.shape, .bar)
        feed(engine, "\u{1b}[4 q")
        XCTAssertEqual(reader.read(engine).cursor?.shape, .underline)
    }

    func testSgrAttributesReachTheCell() throws {
        let (engine, reader) = try make()
        feed(engine, "\u{1b}[1;3;4;9;38;2;255;128;0;48;5;4mA\u{1b}[0mB")
        let cells = reader.read(engine).rows[0].cells
        XCTAssertEqual(cells[0].style.foreground, RGB(255, 128, 0))
        XCTAssertNotNil(cells[0].style.background)
        XCTAssertTrue(cells[0].style.flags.isSuperset(of: [.bold, .italic, .strikethrough]))
        XCTAssertEqual(cells[0].style.underline, .single)
        XCTAssertEqual(cells[1].style, CellStyle())
    }

    func testPaletteColorsResolveThroughTheTheme() throws {
        let (engine, reader) = try make()
        var theme = TerminalTheme.breeze
        theme.ansi[1] = RGB(1, 2, 3)
        try engine.apply(theme)
        feed(engine, "\u{1b}[31mR")
        let frame = reader.read(engine)
        XCTAssertEqual(frame.rows[0].cells[0].style.foreground, RGB(1, 2, 3))
        XCTAssertEqual(frame.background, theme.background)
        XCTAssertEqual(frame.foreground, theme.foreground)
    }

    func testResetKeepsTheHostsThemeAndBlinkingCursor() throws {
        let (engine, reader) = try make()
        var theme = TerminalTheme.breeze
        theme.ansi[1] = RGB(1, 2, 3)
        try engine.apply(theme)
        feed(engine, "\u{1b}[6 q\u{1b}]4;1;#ff0000\u{07}")
        engine.reset()
        feed(engine, "\u{1b}[31mR")
        let frame = reader.read(engine)
        XCTAssertEqual(frame.rows[0].cells[0].style.foreground, RGB(1, 2, 3))
        XCTAssertEqual(frame.background, theme.background)
        XCTAssertEqual(frame.cursor?.shape, .block)
        XCTAssertEqual(frame.cursor?.blinks, true)
    }

    /// S20 — by WCAG relative luminance: the blue is the darker of its pair,
    /// though its largest channel and the mean of its channels are the higher.
    func test2610_0007S20AThemeIsDarkWhenItsBackgroundHasTheLowerLuminance() {
        func theme(background: UInt32, foreground: UInt32) -> TerminalTheme {
            var theme = TerminalTheme.breeze
            theme.background = RGB(hex: background)
            theme.foreground = RGB(hex: foreground)
            return theme
        }
        XCTAssertTrue(theme(background: 0x31363b, foreground: 0xced2d6).isDark)
        XCTAssertFalse(theme(background: 0xfcfcfc, foreground: 0x232629).isDark)
        XCTAssertTrue(theme(background: 0x0000ff, foreground: 0x00a000).isDark)
        XCTAssertFalse(theme(background: 0x808080, foreground: 0x808080).isDark)
    }

    func testWideCharacterOccupiesTwoCells() throws {
        let (engine, reader) = try make()
        feed(engine, "世a")
        let cells = reader.read(engine).rows[0].cells
        XCTAssertEqual(cells[0].text, "世")
        XCTAssertEqual(cells[0].width, .wide)
        XCTAssertEqual(cells[1].width, .spacer)
        XCTAssertEqual(cells[2].text, "a")
        XCTAssertEqual(cells[2].width, .narrow)
    }

    func testGraphemeClusterStaysInOneCell() throws {
        let (engine, reader) = try make()
        feed(engine, "\u{1b}[?2027he\u{301}x")
        let cells = reader.read(engine).rows[0].cells
        XCTAssertEqual(cells[0].text, "e\u{301}")
        XCTAssertEqual(cells[1].text, "x")
    }

    func testOnlyChangedRowsAreReportedDirty() throws {
        let (engine, reader) = try make()
        feed(engine, "one\r\ntwo")
        XCTAssertEqual(reader.read(engine).dirtyRows, IndexSet(0..<3))
        XCTAssertEqual(reader.read(engine).dirtyRows, IndexSet())

        feed(engine, "!")
        let frame = reader.read(engine)
        XCTAssertEqual(frame.dirtyRows, IndexSet(integer: 1))
        XCTAssertEqual(frame.rows[0].text, "one")
        XCTAssertEqual(frame.rows[1].text, "two!")
    }

    /// A default colour changes no row, and a cell with no colour of its own
    /// is drawn in it: the row is not the one of the frame before.
    func testAProgramsOwnBackgroundMakesEveryRowDirty() throws {
        let (engine, reader) = try make()
        try engine.apply(.breeze)
        feed(engine, "one\r\ntwo")
        _ = reader.read(engine)

        feed(engine, "\u{1b}]11;rgb:10/20/30\u{1b}\\")
        let set = reader.read(engine)
        XCTAssertEqual(set.background, RGB(hex: 0x102030))
        XCTAssertEqual(set.dirtyRows, IndexSet(0..<3))
        XCTAssertEqual(set.rows.map(\.text), ["one", "two", ""])

        feed(engine, "\u{1b}]111\u{1b}\\")
        let reset = reader.read(engine)
        XCTAssertEqual(reset.background, TerminalTheme.breeze.background)
        XCTAssertEqual(reset.dirtyRows, IndexSet(0..<3))
    }

    func testAProgramsOwnForegroundMakesEveryRowDirty() throws {
        let (engine, reader) = try make()
        try engine.apply(.breeze)
        feed(engine, "one\r\ntwo")
        _ = reader.read(engine)

        feed(engine, "\u{1b}]10;rgb:aa/bb/cc\u{1b}\\")
        let set = reader.read(engine)
        XCTAssertEqual(set.foreground, RGB(hex: 0xaabbcc))
        XCTAssertEqual(set.dirtyRows, IndexSet(0..<3))
        XCTAssertEqual(set.rows.map(\.text), ["one", "two", ""])

        feed(engine, "\u{1b}]110\u{1b}\\")
        let reset = reader.read(engine)
        XCTAssertEqual(reset.foreground, TerminalTheme.breeze.foreground)
        XCTAssertEqual(reset.dirtyRows, IndexSet(0..<3))
    }

    /// A cell holds the colour its palette index had when its row was read,
    /// and a new entry (OSC 4) changes no row.
    func testANewPaletteEntryReachesTheCellsAlreadyWritten() throws {
        let (engine, reader) = try make()
        try engine.apply(.breeze)
        feed(engine, "\u{1b}[31mR\u{1b}[0m\r\ntwo")
        XCTAssertEqual(reader.read(engine).rows[0].cells[0].style.foreground, TerminalTheme.breeze.ansi[1])

        feed(engine, "\u{1b}]4;1;rgb:aa/00/01\u{1b}\\")
        let set = reader.read(engine)
        XCTAssertEqual(set.rows[0].cells[0].style.foreground, RGB(hex: 0xaa0001))
        XCTAssertEqual(set.dirtyRows, IndexSet(0..<3))

        feed(engine, "\u{1b}]104;1\u{1b}\\")
        let reset = reader.read(engine)
        XCTAssertEqual(reset.rows[0].cells[0].style.foreground, TerminalTheme.breeze.ansi[1])
        XCTAssertEqual(reset.dirtyRows, IndexSet(0..<3))
    }

    /// The cost: the frames after a new colour, which change none, name the
    /// rows that changed and no more.
    func testAFrameThatChangesNoColourNamesOnlyItsOwnRows() throws {
        let (engine, reader) = try make()
        try engine.apply(.breeze)
        feed(engine, "one\r\ntwo")
        _ = reader.read(engine)
        feed(engine, "\u{1b}]11;rgb:10/20/30\u{1b}\\\u{1b}]4;1;rgb:aa/00/01\u{1b}\\")
        _ = reader.read(engine)

        XCTAssertEqual(reader.read(engine).dirtyRows, IndexSet())
        feed(engine, "!")
        XCTAssertEqual(reader.read(engine).dirtyRows, IndexSet(integer: 1))
        XCTAssertEqual(reader.read(engine).dirtyRows, IndexSet())
    }

    func testResizeRedrawsEverything() throws {
        let (engine, reader) = try make()
        feed(engine, "one")
        _ = reader.read(engine)
        try engine.resize(cols: 8, rows: 2, cellWidthPx: 8, cellHeightPx: 16)
        let frame = reader.read(engine)
        XCTAssertEqual(frame.cols, 8)
        XCTAssertEqual(frame.rows.count, 2)
        XCTAssertEqual(frame.dirtyRows, IndexSet(0..<2))
    }

    func testScrolledViewportShowsHistory() throws {
        let (engine, reader) = try make(cols: 8, rows: 2)
        feed(engine, "a\r\nb\r\nc\r\nd")
        XCTAssertEqual(reader.read(engine).rows.map(\.text), ["c", "d"])
        engine.scrollViewport(.rows(-2))
        let frame = reader.read(engine)
        XCTAssertEqual(frame.rows.map(\.text), ["a", "b"])
        XCTAssertNil(frame.cursor)
    }
}
