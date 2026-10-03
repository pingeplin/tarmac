import XCTest
@testable import TarmacTerm

@MainActor
final class TerminalSelectionTests: XCTestCase {
    private let surface = SurfaceGeometry(width: 200, height: 80, cellWidth: 10, cellHeight: 20)
    private var engine: TerminalEngine!
    private var selection: TerminalSelection!
    private var reader: FrameReader!

    override func setUp() async throws {
        engine = try TerminalEngine(cols: 20, rows: 4)
        selection = try TerminalSelection(engine: engine)
        reader = try FrameReader()
        engine.feed(Array("hello world\r\nsecond line".utf8))
    }

    /// A point inside a cell, in surface points. A drag takes in the cell under
    /// it only once it is past ~60% of the cell's width, so drags aim at `past`.
    private func point(_ col: Int, _ row: Int, past: Bool = false) -> SurfacePoint {
        SurfacePoint(x: Double(col) * 10 + (past ? 8 : 5), y: Double(row) * 20 + 10)
    }

    func testADragStoppingShortOfACellsThresholdLeavesItOut() {
        selection.press(point(0, 0), time: 1, surface: surface)
        selection.drag(point(4, 0), surface: surface)
        XCTAssertEqual(selection.text, "hell")
    }

    func testNothingIsSelectedInitially() {
        XCTAssertNil(selection.text)
        XCTAssertNil(reader.read(engine).rows[0].selection)
    }

    func testAPlainClickSelectsNothing() {
        selection.press(point(2, 0), time: 1, surface: surface)
        selection.release(point(2, 0), surface: surface)
        XCTAssertNil(selection.text)
    }

    func testDraggingSelectsTheCellsItCrosses() {
        selection.press(point(0, 0), time: 1, surface: surface)
        selection.drag(point(4, 0, past: true), surface: surface)
        selection.release(point(4, 0), surface: surface)
        XCTAssertEqual(selection.text, "hello")
        XCTAssertEqual(reader.read(engine).rows[0].selection, 0...4)
    }

    func testDraggingAcrossRowsSelectsToTheLineEnds() {
        selection.press(point(6, 0), time: 1, surface: surface)
        selection.drag(point(5, 1, past: true), surface: surface)
        XCTAssertEqual(selection.text, "world\nsecond")
        let frame = reader.read(engine)
        XCTAssertEqual(frame.rows[0].selection?.lowerBound, 6)
        XCTAssertEqual(frame.rows[1].selection, 0...5)
    }

    func testSelectionChangeMarksItsRowsDirty() {
        _ = reader.read(engine)
        selection.press(point(0, 1), time: 1, surface: surface)
        selection.drag(point(3, 1), surface: surface)
        XCTAssertTrue(reader.read(engine).dirtyRows.contains(1))
    }

    func testDoubleClickSelectsTheWord() {
        selection.press(point(7, 0), time: 1, surface: surface)
        selection.release(point(7, 0), surface: surface)
        selection.press(point(7, 0), time: 1.1, surface: surface)
        XCTAssertEqual(selection.text, "world")
    }

    func testTripleClickSelectsTheLine() {
        for time in [1.0, 1.1, 1.2] {
            selection.press(point(7, 0), time: time, surface: surface)
            selection.release(point(7, 0), surface: surface)
        }
        XCTAssertEqual(selection.text, "hello world")
    }

    func testSlowSecondClickIsASingleClick() {
        selection.press(point(7, 0), time: 1, surface: surface)
        selection.release(point(7, 0), surface: surface)
        selection.press(point(7, 0), time: 5, surface: surface)
        XCTAssertNil(selection.text)
    }

    func testClearDropsTheSelection() {
        selection.press(point(0, 0), time: 1, surface: surface)
        selection.drag(point(4, 0), surface: surface)
        selection.clear()
        XCTAssertNil(selection.text)
        XCTAssertNil(reader.read(engine).rows[0].selection)
    }

    func testAClickAfterASelectionClearsIt() {
        selection.press(point(0, 0), time: 1, surface: surface)
        selection.drag(point(4, 0, past: true), surface: surface)
        selection.release(point(4, 0), surface: surface)
        selection.press(point(9, 1), time: 9, surface: surface)
        XCTAssertNil(selection.text)
    }

    func testSelectAllCoversEverything() {
        selection.selectAll()
        XCTAssertEqual(selection.text, "hello world\nsecond line")
    }

    func testSelectionFollowsItsTextThroughScrolling() {
        selection.press(point(0, 1), time: 1, surface: surface)
        selection.drag(point(5, 1, past: true), surface: surface)
        selection.release(point(5, 1), surface: surface)
        engine.feed(Array("\r\nthree\r\nfour\r\nfive".utf8))
        XCTAssertEqual(selection.text, "second")
    }
}
