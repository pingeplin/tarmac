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
