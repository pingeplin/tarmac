import CoreGraphics
import XCTest
@testable import TarmacTerm

@MainActor
final class TerminalRendererTests: XCTestCase {
    private let theme = TerminalTheme.breeze
    private let untouched = RGB(255, 0, 255)

    /// Renders `output` on a `cols`×`rows` grid at `scale` device pixels per point
    /// and returns the canvas to sample.
    private func render(
        _ output: String,
        cols: Int = 8,
        rows: Int = 3,
        scale: CGFloat = 2,
        only drawn: Range<Int>? = nil,
        cursor: CursorDisplay = .hidden,
        preedit: TerminalPreedit? = nil,
        hovering: [LinkSpan] = [],
        face: String? = nil,
        select: ((TerminalSelection, SurfaceGeometry) -> Void)? = nil
    ) throws -> Canvas {
        let fonts = TerminalFonts(size: 16, pixelsPerPoint: scale, family: face)
        let cell = fonts.metrics.cell
        let padding = TerminalPadding(top: 0, left: 0, bottom: 0, right: 0)
        let bounds = CGSize(width: cell.width * CGFloat(cols), height: cell.height * CGFloat(rows))
        let layout = try XCTUnwrap(TerminalGridLayout(bounds: bounds, cell: cell, padding: padding))

        let engine = try TerminalEngine(cols: cols, rows: rows)
        try engine.apply(theme)
        engine.feed(Array(output.utf8))
        if let select { select(try TerminalSelection(engine: engine), layout.surface) }
        let frame = try FrameReader().read(engine)

        let canvas = try Canvas(size: bounds, scale: scale, fill: untouched, layout: layout)
        TerminalRenderer(fonts: fonts, theme: theme)
            .draw(
                frame, rows: drawn ?? 0..<rows, layout: layout, cursor: cursor, preedit: preedit,
                hoveredLink: hovering, in: canvas.context
            )
        return canvas
    }

    /// The composing text covers the terminal's cursor, so without a caret of
    /// its own nothing shows where the next symbol will go.
    func testComposingTextShowsTheInputMethodsCaret() throws {
        let atEnd = try render("", cursor: .focused, preedit: TerminalPreedit(text: "ab", caret: 2))
        XCTAssertFalse(atEnd.rows(containing: theme.cursor, inCols: 2..<3, row: 0).isEmpty)
        let atStart = try render("", cursor: .focused, preedit: TerminalPreedit(text: "ab", caret: 0))
        XCTAssertTrue(atStart.rows(containing: theme.cursor, inCols: 2..<3, row: 0).isEmpty)
    }

    func testTheComposingCaretBlinksWithTheCursor() throws {
        let off = try render("", cursor: .hidden, preedit: TerminalPreedit(text: "ab", caret: 2))
        XCTAssertTrue(off.rows(containing: theme.cursor, inCols: 2..<3, row: 0).isEmpty)
    }

    func testEmptyCellsShowTheThemeBackground() throws {
        let canvas = try render("")
        XCTAssertEqual(canvas.center(col: 3, row: 1), theme.background)
    }

    func testCellBackgroundColourFillsItsCell() throws {
        let canvas = try render("\u{1b}[41m  \u{1b}[0m")
        XCTAssertEqual(canvas.center(col: 0, row: 0), theme.ansi[1])
        XCTAssertEqual(canvas.center(col: 1, row: 0), theme.ansi[1])
        XCTAssertEqual(canvas.center(col: 2, row: 0), theme.background)
    }

    func testAdjacentBackgroundCellsLeaveNoSeam() throws {
        let canvas = try render("\u{1b}[41m    \u{1b}[0m", scale: 1)
        XCTAssertEqual(canvas.colours(inCols: 0..<4, row: 0), [theme.ansi[1]])
    }

    func testGlyphsAreDrawnInTheForegroundColour() throws {
        let canvas = try render("\u{1b}[32mM")
        let colours = canvas.colours(inCols: 0..<1, row: 0)
        XCTAssertTrue(colours.contains(theme.ansi[2]), "an M should put solid foreground pixels in its cell")
        XCTAssertEqual(canvas.colours(inCols: 1..<2, row: 0), [theme.background])
    }

    func testInverseSwapsForegroundAndBackground() throws {
        let canvas = try render("\u{1b}[7m \u{1b}[0m")
        XCTAssertEqual(canvas.center(col: 0, row: 0), theme.foreground)
    }

    func testWideCharacterDrawsAcrossBothOfItsCells() throws {
        let canvas = try render("世")
        XCTAssertGreaterThan(canvas.colours(inCols: 0..<1, row: 0).count, 1)
        XCTAssertGreaterThan(canvas.colours(inCols: 1..<2, row: 0).count, 1)
        XCTAssertEqual(canvas.colours(inCols: 2..<3, row: 0), [theme.background])
    }

    /// A fallback-font cell is drawn through a CoreText line, which moves the
    /// context's text position; the next plain glyph must not inherit it.
    func testPlainGlyphsAfterAFallbackCellStayInTheirOwnCells() throws {
        let canvas = try render("世M\r\nM")
        XCTAssertGreaterThan(canvas.colours(inCols: 2..<3, row: 0).count, 1, "the M after 世")
        XCTAssertGreaterThan(canvas.colours(inCols: 0..<1, row: 1).count, 1, "the M on the next row")
        XCTAssertEqual(canvas.colours(inCols: 3..<8, row: 0), [theme.background])
        XCTAssertEqual(canvas.colours(inCols: 1..<8, row: 1), [theme.background])
    }

    func testUnderlineIsDrawnBelowTheGlyph() throws {
        let plain = try render("\u{1b}[32m ")
        let underlined = try render("\u{1b}[32;4m ")
        XCTAssertEqual(plain.colours(inCols: 0..<1, row: 0), [theme.background])
        XCTAssertTrue(underlined.colours(inCols: 0..<1, row: 0).contains(theme.ansi[2]))
    }

    func testAHoveredLinkIsUnderlinedOnEveryRowItRunsOver() throws {
        let canvas = try render("", hovering: [LinkSpan(row: 0, cols: 2...7), LinkSpan(row: 1, cols: 0...3)])
        XCTAssertEqual(canvas.colours(inCols: 0..<2, row: 0), [theme.background])
        XCTAssertTrue(canvas.colours(inCols: 2..<8, row: 0).contains(theme.foreground))
        XCTAssertTrue(canvas.colours(inCols: 0..<4, row: 1).contains(theme.foreground))
        XCTAssertEqual(canvas.colours(inCols: 4..<8, row: 1), [theme.background])
        XCTAssertEqual(canvas.colours(inCols: 0..<8, row: 2), [theme.background])
    }

    func testCurlyUnderlineUndulatesWhereASingleOneIsFlat() throws {
        let single = try render("\u{1b}[32;4m    ")
        let curly = try render("\u{1b}[32;4:3m    ")
        let flat = single.rows(containing: theme.ansi[2], inCols: 0..<4, row: 0)
        let wavy = curly.rows(containing: theme.ansi[2], inCols: 0..<4, row: 0)
        XCTAssertFalse(flat.isEmpty)
        XCTAssertGreaterThan(wavy.count, flat.count)
    }

    // MARK: italic in a family that has none

    /// How far the ink at the top of the first row starts to the right of the
    /// ink at its foot, in pixels, for `output` set in Monaco.
    private func lean(_ output: String) throws -> Int {
        try render(output, face: "Monaco").lean(inCols: 0..<3, row: 0, on: theme.background)
    }

    func testItalicLeansRightWhereTheFamilyHasNone() throws {
        XCTAssertEqual(try lean(" |"), 0)
        XCTAssertGreaterThanOrEqual(try lean("\u{1b}[3m |"), 4)
    }

    /// A cluster is drawn as a CoreText line, not as one glyph.
    func testAnItalicClusterLeansTheSameWay() throws {
        XCTAssertGreaterThanOrEqual(try lean("\u{1b}[3m |\u{323}"), 4)
    }

    /// A rule that leans no longer meets the one in the row below.
    func testLineDrawingCharactersNeverLean() throws {
        for joiner in ["│", "█"] {
            XCTAssertEqual(try lean("\u{1b}[3m " + joiner), try lean(" " + joiner), joiner)
        }
    }

    func testFocusedBlockCursorFillsItsCell() throws {
        let canvas = try render("ab", cursor: .focused)
        XCTAssertEqual(canvas.center(col: 2, row: 0), theme.cursor)
    }

    func testUnfocusedCursorIsHollow() throws {
        let canvas = try render("ab", cursor: .unfocused)
        XCTAssertEqual(canvas.center(col: 2, row: 0), theme.background)
        XCTAssertTrue(canvas.colours(inCols: 2..<3, row: 0).contains(theme.cursor))
    }

    func testHiddenCursorIsNotDrawn() throws {
        let canvas = try render("ab", cursor: .hidden)
        XCTAssertEqual(canvas.colours(inCols: 2..<3, row: 0), [theme.background])
    }

    func testSelectionTintsTheSelectedCells() throws {
        let canvas = try render("abcdef") { selection, surface in
            selection.press(SurfacePoint(x: 1, y: 5), time: 1, surface: surface)
            selection.drag(SurfacePoint(x: Double(surface.cellWidth) * 2.9, y: 5), surface: surface)
        }
        let tinted = theme.background.blended(with: theme.selection, alpha: theme.selectionAlpha)
        XCTAssertTrue(canvas.colours(inCols: 0..<3, row: 0).contains(tinted))
        XCTAssertFalse(canvas.colours(inCols: 3..<8, row: 0).contains(tinted))
    }

    func testOnlyTheRequestedRowsAreDrawn() throws {
        let canvas = try render("a\r\nb\r\nc", only: 1..<2)
        XCTAssertEqual(canvas.center(col: 5, row: 0), untouched)
        XCTAssertEqual(canvas.center(col: 5, row: 1), theme.background)
        XCTAssertEqual(canvas.center(col: 5, row: 2), untouched)
    }
}

/// A top-down bitmap the renderer draws into, read back in grid coordinates.
struct Canvas {
    let context: CGContext
    let layout: TerminalGridLayout
    let scale: CGFloat

    init(size: CGSize, scale: CGFloat, fill: RGB, layout: TerminalGridLayout) throws {
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(fill.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Top-down points, like a flipped NSView's drawing context.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        self.layout = layout
        self.scale = scale
    }

    private func pixel(_ x: Int, _ y: Int) -> RGB {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return RGB(data[offset], data[offset + 1], data[offset + 2])
    }

    func center(col: Int, row: Int) -> RGB {
        let rect = layout.rect(col: col, row: row)
        return pixel(Int(rect.midX * scale), Int(rect.midY * scale))
    }

    /// The pixel rows of a span of cells that contain `colour`.
    func rows(containing colour: RGB, inCols cols: Range<Int>, row: Int) -> Set<Int> {
        let rect = layout.rect(col: cols.lowerBound, row: row, span: cols.count)
        var found = Set<Int>()
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) where pixel(x, y) == colour {
                found.insert(y)
            }
        }
        return found
    }

    /// The first pixel column with ink in the top inked pixel row of a span of
    /// cells, less that of the bottom inked row: how far the ink leans right.
    func lean(inCols cols: Range<Int>, row: Int, on background: RGB) throws -> Int {
        let rect = layout.rect(col: cols.lowerBound, row: row, span: cols.count)
        let columns = Int(rect.minX * scale)..<Int(rect.maxX * scale)
        let starts = (Int(rect.minY * scale)..<Int(rect.maxY * scale)).compactMap { y in
            columns.first { pixel($0, y) != background }
        }
        return try XCTUnwrap(starts.first) - XCTUnwrap(starts.last)
    }

    /// Every distinct colour inside a span of cells, inset by one pixel so a
    /// neighbour's antialiasing is not counted.
    func colours(inCols cols: Range<Int>, row: Int) -> Set<RGB> {
        let rect = layout.rect(col: cols.lowerBound, row: row, span: cols.count)
        var found = Set<RGB>()
        for y in Int(rect.minY * scale) + 1..<Int(rect.maxY * scale) - 1 {
            for x in Int(rect.minX * scale) + 1..<Int(rect.maxX * scale) - 1 {
                found.insert(pixel(x, y))
            }
        }
        return found
    }
}
