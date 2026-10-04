import AppKit
import XCTest
@testable import TarmacTerm

@MainActor
final class TerminalViewTests: XCTestCase {
    private var view: TerminalView!
    private var window: NSWindow!
    private var sent: [UInt8] = []
    private var resizes: [[Int]] = []

    private var sentText: String { String(decoding: sent, as: UTF8.self) }

    override func setUp() async throws {
        ShippedFonts.registered
        view = try TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.onInput = { [unowned self] in self.sent.append(contentsOf: $0) }
        view.onResize = { [unowned self] in self.resizes.append([$0, $1]) }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        sent = []
        resizes = []
    }

    private func feed(_ text: String) {
        view.feed(Data(text.utf8))
    }

    private func key(
        _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], unmodified: String? = nil
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: unmodified ?? characters, isARepeat: false, keyCode: code
        )!
    }

    // MARK: layout

    func testGridFollowsTheViewSize() throws {
        let layout = try XCTUnwrap(view.gridLayout)
        XCTAssertEqual(view.cols, layout.cols)
        XCTAssertEqual(view.rows, layout.rows)
        XCTAssertGreaterThan(view.cols, 20)
    }

    func testResizingToADifferentGridTellsTheHostOnce() throws {
        let cell = try XCTUnwrap(view.gridLayout).cell
        view.setFrameSize(NSSize(width: 600 + cell.width * 3, height: 400))
        XCTAssertEqual(resizes.count, 1)
        XCTAssertEqual(resizes.last, [view.cols, view.rows])
    }

    func testResizingWithinTheSameGridIsSilent() {
        view.setFrameSize(NSSize(width: 601, height: 400))
        XCTAssertEqual(resizes, [])
    }

    // MARK: drawing

    /// AppKit can hand a view a dirty rect larger than its bounds; a card's
    /// header sits right above the terminal and must not be painted over.
    func testDrawingStaysInsideTheViewsBounds() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 700, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.magenta.setFill()
        NSRect(x: 0, y: 0, width: 700, height: 500).fill()
        context.cgContext.translateBy(x: 50, y: 50)
        view.draw(NSRect(x: -50, y: -50, width: 700, height: 500))
        NSGraphicsContext.restoreGraphicsState()

        let outside = try XCTUnwrap(rep.colorAt(x: 10, y: 10))
        XCTAssertEqual(outside.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(outside.greenComponent, 0, accuracy: 0.01)
        let inside = try XCTUnwrap(rep.colorAt(x: 350, y: 250))
        XCTAssertLessThan(inside.redComponent, 0.5)
    }

    /// Layer display can hand over a strip just outside the bounds; the
    /// intersection is then the null rect, whose origin is infinite.
    func testADirtyRectThatMissesTheBoundsDrawsNothing() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 700, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSColor.magenta.setFill()
        NSRect(x: 0, y: 0, width: 700, height: 500).fill()
        view.draw(NSRect(x: 0, y: -31.76, width: 468, height: 1.57))
        NSGraphicsContext.restoreGraphicsState()

        let untouched = try XCTUnwrap(rep.colorAt(x: 300, y: 200))
        XCTAssertEqual(untouched.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(untouched.greenComponent, 0, accuracy: 0.01)
    }

    /// A redraw is clipped to the invalidated rect. At a fractional zoom a row's
    /// edge falls inside a device pixel, so the damage must reach past the row
    /// or that pixel keeps a blend of the old content.
    func testARowsDamageReachesPastItsEdges() throws {
        let layout = try XCTUnwrap(view.gridLayout)
        let row = layout.rowRect(3)
        let damage = view.damageRect(forRow: 3)
        XCTAssertLessThan(damage.minY, row.minY)
        XCTAssertGreaterThan(damage.maxY, row.maxY)
        XCTAssertTrue(view.bounds.contains(damage))
        XCTAssertEqual(view.damageRect(forRow: 0).minY, max(layout.rowRect(0).minY - 1, 0))
    }

    func testOutputIsReadableBack() {
        feed("hello")
        XCTAssertEqual(view.plainText(), "hello")
    }

    /// A reconnect replays the daemon's scrollback ring into a card that may
    /// already hold that history; the host resets first so nothing shows twice.
    func testResetDropsTheScreenScrollbackAndSelection() {
        feed((1...200).map { "line\($0)" }.joined(separator: "\r\n"))
        view.selectAll(nil)
        view.reset()
        XCTAssertEqual(view.plainText(), "")
        XCTAssertFalse(view.hasSelection)
        XCTAssertEqual(view.engine.scrollbar.total, view.rows)
        feed("fresh")
        XCTAssertEqual(view.plainText(), "fresh")
    }

    func testResetKeepsTheGrid() throws {
        let cols = view.cols, rows = view.rows
        view.reset()
        XCTAssertEqual(view.cols, cols)
        XCTAssertEqual(view.rows, rows)
        feed("\u{1b}[31mR")
        XCTAssertEqual(resizes, [])
    }

    // MARK: grid access

    func testTheViewportIsReadableCellByCell() throws {
        feed("a世b\r\nx")
        let cells = view.viewportCells()
        XCTAssertEqual(cells.count, view.rows)
        XCTAssertEqual(cells[0].count, view.cols)
        XCTAssertEqual(Array(cells[0].prefix(5)), ["a", "世", "", "b", ""])
        XCTAssertEqual(cells[1][0], "x")
    }

    func testACellsRectIsInViewCoordinates() throws {
        let layout = try XCTUnwrap(view.gridLayout)
        XCTAssertEqual(view.cellRect(col: 3, row: 2), layout.rect(col: 3, row: 2))
        XCTAssertNil(view.cellRect(col: view.cols, row: 0))
        XCTAssertNil(view.cellRect(col: 0, row: -1))
    }

    // MARK: keys

    func testPlainKeySendsItsCharacter() {
        view.keyDown(with: key("a", code: 0x00))
        XCTAssertEqual(sentText, "a")
    }

    func testControlLetterSendsItsControlCode() {
        view.keyDown(with: key("\u{03}", code: 0x08, flags: .control, unmodified: "c"))
        XCTAssertEqual(sent, [0x03])
    }

    /// AppKit's text system binds ⌃Q to quotedInsert:, which swallows the next
    /// key as a literal. A terminal has no such state: ⌃Q is just XON.
    func testAControlChordLeavesNoStateInTheTextSystem() {
        view.keyDown(with: key("\u{11}", code: 0x0c, flags: .control, unmodified: "q"))
        view.keyDown(with: key("B", code: 0x0b, flags: .shift, unmodified: "B"))
        view.keyDown(with: key("\u{16}", code: 0x09, flags: .control, unmodified: "v"))
        view.keyDown(with: key("x", code: 0x07))
        XCTAssertEqual(sent, [0x11, 0x42, 0x16, 0x78])
    }

    func testNamedKeysAreEncoded() {
        view.keyDown(with: key("\r", code: 0x24))
        view.keyDown(with: key("\u{f700}", code: 0x7e, flags: [.function, .numericPad]))
        XCTAssertEqual(sentText, "\r\u{1b}[A")
    }

    func testOptionKeySendsMetaPrefix() {
        view.keyDown(with: key("∫", code: 0x0b, flags: .option, unmodified: "b"))
        XCTAssertEqual(sentText, "\u{1b}b")
    }

    /// Under the kitty protocol a key is named by its code point, and a CJK
    /// input source types a phonetic symbol where the Latin layout has a letter.
    func testOptionKeyIsNamedByItsLatinLetterUnderTheKittyProtocol() {
        feed("\u{1b}[>1u")
        view.keyDown(with: key("∫", code: 0x0b, flags: .option, unmodified: "b"))
        XCTAssertEqual(sentText, "\u{1b}[98;3u")
    }

    func testHostKeyPolicyPreemptsTheEncoder() {
        view.keyOverride = { $0.keyCode == 0x33 && $0.mods == .command ? [0x15] : nil }
        view.keyDown(with: key("\u{7f}", code: 0x33, flags: .command))
        view.keyDown(with: key("\u{7f}", code: 0x33))
        XCTAssertEqual(sent, [0x15, 0x7f])
    }

    func testTypingReportsActivity() {
        var activity = 0
        view.onActivity = { activity += 1 }
        view.keyDown(with: key("a", code: 0x00))
        XCTAssertEqual(activity, 1)
    }

    func testTypingClearsTheSelectionAndReturnsToTheLiveScreen() {
        feed((1...100).map { "line\($0)" }.joined(separator: "\r\n"))
        view.selectAll(nil)
        view.engine.scrollViewport(.rows(-5))
        XCTAssertTrue(view.hasSelection)

        view.keyDown(with: key("a", code: 0x00))
        XCTAssertFalse(view.hasSelection)
        XCTAssertTrue(view.engine.isViewportAtBottom)
    }

    // MARK: links

    private func mouse(_ type: NSEvent.EventType, col: Int, row: Int, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let cell = try XCTUnwrap(view.gridLayout).rect(col: col, row: row)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: view.convert(CGPoint(x: cell.midX, y: cell.midY), to: nil), modifierFlags: flags,
            timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func click(col: Int, row: Int) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, col: col, row: row))
        view.mouseUp(with: try mouse(.leftMouseUp, col: col, row: row))
    }

    func testClickingAUrlOpensIt() throws {
        var opened: [String] = []
        view.onOpenLink = { opened.append($0) }
        feed("see https://example.com/x now")
        try click(col: 6, row: 0)
        XCTAssertEqual(opened, ["https://example.com/x"])
        try click(col: 1, row: 0)
        XCTAssertEqual(opened.count, 1)
    }

    func testClickingAnOsc8HyperlinkOpensItsTarget() throws {
        var opened: [String] = []
        view.onOpenLink = { opened.append($0) }
        feed("\u{1b}]8;;https://example.com/doc\u{1b}\\here\u{1b}]8;;\u{1b}\\")
        try click(col: 1, row: 0)
        XCTAssertEqual(opened, ["https://example.com/doc"])
    }

    /// A host that clicks on the view's behalf asks first, so its click only
    /// focuses.
    func testTheViewSaysWhereAClickWouldOpenALink() throws {
        feed("see https://example.com/x now\r\n\u{1b}]8;;https://example.com/doc\u{1b}\\here\u{1b}]8;;\u{1b}\\ end")
        let layout = try XCTUnwrap(view.gridLayout)
        func centre(col: Int, row: Int) -> NSPoint {
            let cell = layout.rect(col: col, row: row)
            return NSPoint(x: cell.midX, y: cell.midY)
        }
        XCTAssertTrue(view.hasLink(at: centre(col: 6, row: 0)))
        XCTAssertFalse(view.hasLink(at: centre(col: 1, row: 0)))
        XCTAssertTrue(view.hasLink(at: centre(col: 1, row: 1)))
        XCTAssertFalse(view.hasLink(at: centre(col: 6, row: 1)))
        XCTAssertFalse(view.hasLink(at: NSPoint(x: -4, y: -4)))
        XCTAssertFalse(view.hasLink(at: NSPoint(x: 5_000, y: 5_000)))
    }

    /// The point is in the view's coordinates, not the grid's: the padding
    /// around the grid shifts every cell, so the answer changes exactly at the
    /// link's first and last cells.
    func testALinkEndsAtItsFirstAndLastCells() throws {
        feed("see https://example.com/x now")
        let layout = try XCTUnwrap(view.gridLayout)
        func centre(_ col: Int) -> NSPoint {
            let cell = layout.rect(col: col, row: 0)
            return NSPoint(x: cell.midX, y: cell.midY)
        }
        XCTAssertFalse(view.hasLink(at: centre(3)))
        XCTAssertTrue(view.hasLink(at: centre(4)))
        XCTAssertTrue(view.hasLink(at: centre(24)))
        XCTAssertFalse(view.hasLink(at: centre(25)))
    }

    func testAViewTooSmallForAGridHasNoLinks() throws {
        let empty = try TerminalView(frame: .zero)
        XCTAssertNil(empty.gridLayout)
        XCTAssertFalse(empty.hasLink(at: .zero))
    }

    func testDraggingAcrossAUrlSelectsInsteadOfOpening() throws {
        var opened: [String] = []
        view.onOpenLink = { opened.append($0) }
        feed("see https://example.com/x now")
        view.mouseDown(with: try mouse(.leftMouseDown, col: 4, row: 0))
        view.mouseDragged(with: try mouse(.leftMouseDragged, col: 12, row: 0))
        view.mouseUp(with: try mouse(.leftMouseUp, col: 12, row: 0))
        XCTAssertEqual(opened, [])
        XCTAssertTrue(view.hasSelection)
    }

    func testAProgramThatTracksTheMouseGetsTheClickInstead() throws {
        var opened: [String] = []
        view.onOpenLink = { opened.append($0) }
        feed("https://example.com/x\u{1b}[?1000h\u{1b}[?1006h")
        try click(col: 3, row: 0)
        XCTAssertEqual(opened, [])
        XCTAssertEqual(sentText, "\u{1b}[<0;4;1M\u{1b}[<0;4;1m")
    }

    /// A tracking area reports moves over the whole view, including where
    /// another card lies on top of it.
    func testPointerMovesOverAViewStackedAboveAreNotThisTerminals() throws {
        feed("\u{1b}[?1003h\u{1b}[?1006h")
        let content = try XCTUnwrap(view.superview)
        let covered = try XCTUnwrap(view.gridLayout).rect(col: 0, row: 0, span: 10)
        content.addSubview(NSView(frame: view.convert(covered, to: content)))
        view.mouseMoved(with: try mouse(.mouseMoved, col: 3, row: 0))
        XCTAssertEqual(sentText, "")
        view.mouseMoved(with: try mouse(.mouseMoved, col: 20, row: 0))
        XCTAssertEqual(sentText, "\u{1b}[<35;21;1M")
    }

    // MARK: context menu

    func testRightClickSelectsTheWordAndOffersCopyPaste() throws {
        feed("hello world")
        let menu = try XCTUnwrap(view.menu(for: try mouse(.rightMouseDown, col: 7, row: 0)))
        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Paste", "Select All"])
        view.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "world")
    }

    func testRightClickInsideASelectionKeepsIt() throws {
        feed("hello world")
        view.selectAll(nil)
        _ = view.menu(for: try mouse(.rightMouseDown, col: 7, row: 0))
        view.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello world")
    }

    func testAProgramThatTracksTheMouseGetsNoContextMenu() throws {
        feed("hello\u{1b}[?1000h")
        XCTAssertNil(view.menu(for: try mouse(.rightMouseDown, col: 1, row: 0)))
    }

    // MARK: wheel

    private func wheel(lines: Int32) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0
        ))
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    func testWheelScrollsIntoScrollback() throws {
        feed((1...200).map { "line\($0)" }.joined(separator: "\r\n"))
        view.scrollWheel(with: try wheel(lines: 3))
        XCTAssertFalse(view.engine.isViewportAtBottom)
        XCTAssertEqual(sent, [])
    }

    /// Which card a wheel event reaches is the board's decision, not the view's:
    /// an event that arrives is scrolled even without keyboard focus.
    func testWheelScrollsWithoutKeyboardFocus() throws {
        feed((1...200).map { "line\($0)" }.joined(separator: "\r\n"))
        window.makeFirstResponder(nil)
        view.scrollWheel(with: try wheel(lines: 3))
        XCTAssertFalse(view.engine.isViewportAtBottom)
    }

    func testWheelGoesToAProgramThatTracksTheMouse() throws {
        feed("\u{1b}[?1000h\u{1b}[?1006h")
        view.scrollWheel(with: try wheel(lines: 1))
        XCTAssertTrue(sentText.hasPrefix("\u{1b}[<64;"), sentText.debugDescription)
    }

    // MARK: scroll position (2610.0003 S14, S26)

    private let tenLines = (1...10).map { "line\($0)" }.joined(separator: "\r\n")

    /// Sizes the view to exactly `rows` rows, keeping its width.
    private func resize(rows: Int) throws {
        let cell = try XCTUnwrap(view.gridLayout).cell
        let height = view.padding.top + view.padding.bottom + cell.height * CGFloat(rows)
        view.setFrameSize(NSSize(width: view.frame.width, height: height))
        XCTAssertEqual(view.rows, rows)
    }

    /// The frame read a feed schedules, run now.
    private func read() {
        _ = view.viewportCells()
    }

    func test2610S14TheHostIsToldWhereTheViewportIsWheneverThatChanges() throws {
        try resize(rows: 3)
        var told: [TerminalScrollbar] = []
        view.onScrollChanged = { told.append($0) }

        feed(tenLines)
        read()
        XCTAssertEqual(told.last, TerminalScrollbar(total: 10, offset: 7, visible: 3))

        view.scrollWheel(with: try wheel(lines: 2))
        read()
        XCTAssertEqual(told.last, TerminalScrollbar(total: 10, offset: 5, visible: 3))

        try resize(rows: 5)
        XCTAssertEqual(told.last, view.engine.scrollbar)
        XCTAssertEqual(told.last?.visible, 5)
    }

    /// Nothing was told while there was no one to tell, so the first check
    /// after the callback is set reports, though the scrollbar has not moved.
    func test2610S14ACallbackSetLateIsToldAtTheNextFrameRead() throws {
        try resize(rows: 3)
        feed(tenLines)
        read()
        let scrollbar = view.engine.scrollbar

        var told: [TerminalScrollbar] = []
        view.onScrollChanged = { told.append($0) }
        feed("x")
        read()
        XCTAssertEqual(view.engine.scrollbar, scrollbar)
        XCTAssertEqual(told, [scrollbar])
    }

    /// A relayout checks whether or not it resizes the engine.
    func test2610S14ACallbackSetLateIsToldByARelayoutThatKeepsTheGrid() throws {
        try resize(rows: 3)
        feed(tenLines)
        read()

        var told: [TerminalScrollbar] = []
        view.onScrollChanged = { told.append($0) }
        resizes = []
        view.setFrameSize(NSSize(width: view.frame.width + 1, height: view.frame.height))
        XCTAssertEqual(resizes, [])
        XCTAssertEqual(told, [view.engine.scrollbar])
    }

    /// A view too small for a grid draws nothing, and its history still grows.
    func test2610S14AFrameReadIsToldThoughTheViewHasNoGrid() throws {
        try resize(rows: 3)
        var told: [TerminalScrollbar] = []
        view.onScrollChanged = { told.append($0) }
        view.setFrameSize(.zero)
        XCTAssertNil(view.gridLayout)

        feed(tenLines)
        read()
        XCTAssertEqual(told.last, TerminalScrollbar(total: 10, offset: 7, visible: 3))
    }

    func test2610S26OutputThatLeavesTheScrollbarAsItWasIsNotToldAgain() throws {
        try resize(rows: 3)
        var told: [TerminalScrollbar] = []
        view.onScrollChanged = { told.append($0) }
        feed(tenLines)
        read()
        let before = told
        XCTAssertEqual(before, [TerminalScrollbar(total: 10, offset: 7, visible: 3)])

        feed("x")
        read()
        XCTAssertEqual(view.viewportCells().last?.joined().hasSuffix("line10x"), true)
        XCTAssertEqual(told, before)
    }

    func test2610S26ARelayoutThatLeavesTheScrollbarAsItWasIsNotToldAgain() throws {
        try resize(rows: 3)
        var told: [TerminalScrollbar] = []
        view.onScrollChanged = { told.append($0) }
        feed(tenLines)
        read()
        let before = told
        XCTAssertEqual(before, [TerminalScrollbar(total: 10, offset: 7, visible: 3)])

        resizes = []
        view.setFrameSize(NSSize(width: view.frame.width + 1, height: view.frame.height))
        XCTAssertEqual(resizes, [])
        XCTAssertEqual(told, before)
    }

    func test2610S26TheAlternateScreenHasNothingToScroll() throws {
        try resize(rows: 3)
        var told: [TerminalScrollbar] = []
        view.onScrollChanged = { told.append($0) }
        feed(tenLines)
        read()

        feed("\u{1b}[?1049h")
        read()
        XCTAssertEqual(told.last, TerminalScrollbar(total: 3, offset: 0, visible: 3))
    }

    // MARK: scroll to a row (spec 2610.0004)

    /// Runs what the main queue holds, so that no frame read is left
    /// scheduled: `read()` then reads only one that was scheduled since.
    private func settle() {
        let settled = expectation(description: "the main queue ran")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1)
    }

    /// A 3-row view holding ten lines, with someone to tell.
    private func scrolledBack() throws -> () -> [TerminalScrollbar] {
        try resize(rows: 3)
        var told: [TerminalScrollbar] = []
        view.onScrollChanged = { told.append($0) }
        feed(tenLines)
        read()
        XCTAssertEqual(told.last, TerminalScrollbar(total: 10, offset: 7, visible: 3))
        settle()
        return { told }
    }

    /// `scroll(to:)` schedules its own frame read: none is pending when it is
    /// asked.
    func test2610_0004S13ScrollToGoesToTheNearestRowAndTheHostIsTold() throws {
        let told = try scrolledBack()
        let rows: [(Double, Int)] = [(2.4, 2), (2.5, 3), (99, 7), (-4, 0)]
        for (asked, row) in rows {
            view.scroll(to: asked)
            read()
            XCTAssertEqual(told().last, TerminalScrollbar(total: 10, offset: row, visible: 3), "asked \(asked)")
            settle()
        }
    }

    func test2610_0004S34ScrollToANumberThatIsNoRowScrollsNothing() throws {
        let told = try scrolledBack()
        view.scroll(to: 2)
        read()
        let before = told()
        XCTAssertEqual(before.last?.offset, 2)

        for asked in [Double.nan, .infinity, -.infinity] {
            view.scroll(to: asked)
            read()
            XCTAssertEqual(told(), before, "asked \(asked)")
        }
    }

    func test2610_0004S34ScrollToFarPastEitherEndIsThatEnd() throws {
        let told = try scrolledBack()
        view.scroll(to: -1e300)
        read()
        XCTAssertEqual(told().last?.offset, 0)
        view.scroll(to: 1e300)
        read()
        XCTAssertEqual(told().last?.offset, 7)
    }

    func test2610_0004S34ScrollToOnTheAlternateScreenScrollsNothing() throws {
        _ = try scrolledBack()
        feed("\u{1b}[?1049h")
        read()
        XCTAssertEqual(view.engine.scrollbar, TerminalScrollbar(total: 3, offset: 0, visible: 3))

        view.scroll(to: 2)
        read()
        XCTAssertEqual(view.engine.scrollbar, TerminalScrollbar(total: 3, offset: 0, visible: 3))
    }

    func testWheelOnTheAlternateScreenSendsArrowKeys() throws {
        feed("\u{1b}[?1049h")
        view.scrollWheel(with: try wheel(lines: -1))
        XCTAssertEqual(sentText, "\u{1b}[B")
    }

    /// Italic ink overhangs its cell: what the last column leaves in the
    /// padding has to go when its row is redrawn.
    func testARowsDamageReachesBothEdgesOfTheView() {
        let damage = view.damageRect(forRow: 2)
        XCTAssertEqual(damage.minX, view.bounds.minX)
        XCTAssertEqual(damage.maxX, view.bounds.maxX)
    }

    // MARK: IME

    func testCompositionHoldsKeysBackUntilItCommits() {
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(sent, [])

        view.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(sentText, "你")
    }

    func testTheInputMethodsCaretIsKeptWithTheComposingText() {
        let nowhere = NSRange(location: NSNotFound, length: 0)
        view.setMarkedText("中文", selectedRange: NSRange(location: 1, length: 0), replacementRange: nowhere)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        view.insertText("中文", replacementRange: nowhere)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
    }

    /// Zhuyin asks where the whole composing text is, then where its last
    /// character is, wherever its caret stands: the answer is the caret.
    func testTheCandidateWindowFollowsTheInputMethodsCaret() throws {
        let cell = try XCTUnwrap(view.gridLayout).cell
        let nowhere = NSRange(location: NSNotFound, length: 0)
        let whole = NSRange(location: 0, length: 4), last = NSRange(location: 3, length: 1)
        view.setMarkedText("abcd", selectedRange: NSRange(location: 0, length: 0), replacementRange: nowhere)
        let start = view.firstRect(forCharacterRange: whole, actualRange: nil)
        view.setMarkedText("abcd", selectedRange: NSRange(location: 2, length: 0), replacementRange: nowhere)
        // The composing text is set at the font's own advance, a little off the grid's.
        XCTAssertEqual(view.firstRect(forCharacterRange: whole, actualRange: nil).minX - start.minX, 2 * cell.width, accuracy: 1)
        XCTAssertEqual(view.firstRect(forCharacterRange: last, actualRange: nil).minX - start.minX, 2 * cell.width, accuracy: 1)
    }

    func testTheCandidateWindowOpensUnderTheClauseBeingConverted() throws {
        let cell = try XCTUnwrap(view.gridLayout).cell
        let nowhere = NSRange(location: NSNotFound, length: 0)
        let whole = NSRange(location: 0, length: 4)
        view.setMarkedText("abcd", selectedRange: NSRange(location: 0, length: 0), replacementRange: nowhere)
        let start = view.firstRect(forCharacterRange: whole, actualRange: nil)
        view.setMarkedText("abcd", selectedRange: NSRange(location: 1, length: 2), replacementRange: nowhere)
        XCTAssertEqual(view.firstRect(forCharacterRange: whole, actualRange: nil).minX - start.minX, cell.width, accuracy: 1)
    }

    func testChordSeenDuringCompositionSaysSo() {
        var seen: [Bool] = []
        view.keyOverride = { seen.append($0.isComposing); return nil }
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: key("\u{7f}", code: 0x33))
        XCTAssertEqual(seen, [true])
    }

    func testKeyReleasesDuringCompositionStayWithTheIme() {
        feed("\u{1b}[>3u")
        let release = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
            context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 0x2d
        )!
        view.keyUp(with: release)
        XCTAssertFalse(sent.isEmpty, "a kitty program that asked for releases gets them")

        sent = []
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyUp(with: release)
        XCTAssertEqual(sent, [])
    }

    // MARK: clipboard

    func testPasteHonoursBracketedMode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("a\nb", forType: .string)
        view.paste(nil)
        XCTAssertEqual(sentText, "a\rb")

        sent = []
        feed("\u{1b}[?2004h")
        view.paste(nil)
        XCTAssertEqual(sentText, "\u{1b}[200~a\nb\u{1b}[201~")
    }

    func testCopyPutsTheSelectionOnThePasteboard() {
        feed("hello")
        view.selectAll(nil)
        NSPasteboard.general.clearContents()
        view.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")
    }

    func testCopyIsOfferedOnlyWithASelection() {
        let item = NSMenuItem(title: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        XCTAssertFalse(view.validateUserInterfaceItem(item))
        feed("hello")
        view.selectAll(nil)
        XCTAssertTrue(view.validateUserInterfaceItem(item))
    }

    func testProgramClipboardWritesAreTheHostsDecision() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("mine", forType: .string)
        feed("\u{1b}]52;c;aGVsbG8=\u{07}")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "mine")

        var offered: [String] = []
        view.onClipboardWrite = { offered.append($0) }
        feed("\u{1b}]52;c;aGVsbG8=\u{07}")
        XCTAssertEqual(offered, ["hello"])
    }

    func testClipboardAccessIsAdvertisedOnlyWhenTheHostTakesWrites() {
        feed("\u{1b}[c")
        XCTAssertEqual(sentText, "\u{1b}[?62;22c")
        sent = []
        view.onClipboardWrite = { _ in }
        feed("\u{1b}[c")
        XCTAssertEqual(sentText, "\u{1b}[?62;22;52c")
        sent = []
        view.onClipboardWrite = nil
        feed("\u{1b}[c")
        XCTAssertEqual(sentText, "\u{1b}[?62;22c")
    }

    // MARK: focus

    func testFocusChangesAreReportedWhenTheProgramAsks() {
        feed("\u{1b}[?1004h")
        window.makeFirstResponder(nil)
        window.makeFirstResponder(view)
        XCTAssertEqual(sentText, "\u{1b}[O\u{1b}[I")
    }

    /// AppKit can drop first responder without calling resign (a restack that
    /// re-parents the view), then hand it back: the program must not see a
    /// second focus-in with no focus-out between.
    func testFocusIsReportedOnlyWhenItChanges() {
        feed("\u{1b}[?1004h")
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertEqual(sentText, "")
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertEqual(sentText, "\u{1b}[O")
    }

    /// AppKit calls this on every frame-to-bounds scale change (each zoom step)
    /// and the board re-parents cards on each click; neither changes the
    /// display's backing scale, so the fonts and glyph cache must survive.
    func testFontsAreRebuiltOnlyWhenTheBackingScaleChanges() {
        let before = view.fontGeneration
        view.viewDidChangeBackingProperties()
        view.viewDidMoveToWindow()
        XCTAssertEqual(view.fontGeneration, before)
    }

    /// A card built off-window spawns its PTY from this grid; guessing the
    /// density would spawn at one size and correct it on mount.
    func testAnUnwindowedViewMeasuresItsGridAtTheGivenBackingScale() throws {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let cells = try [1, 2].map { scale -> CGSize? in
            let view = try TerminalView(frame: frame, backingScale: scale)
            XCTAssertEqual(view.gridLayout?.cell, TerminalFonts(size: 16, pixelsPerPoint: scale).metrics.cell)
            return view.gridLayout?.cell
        }
        XCTAssertNotEqual(cells[0], cells[1])
    }

    // MARK: program replies

    func testQueriesAreAnsweredThroughTheInputPath() {
        feed("\u{1b}[6n")
        XCTAssertEqual(sentText, "\u{1b}[1;1R")
    }

    /// Whoever asked is no longer waiting: an answer would arrive at today's
    /// prompt as typed text.
    func testReplayedHistoryAnswersNothingAndRingsNothing() {
        var bells = 0
        view.onBell = { bells += 1 }
        view.replay(Data("old\u{1b}[6n\u{1b}[c\u{07}".utf8))
        XCTAssertEqual(sent, [])
        XCTAssertEqual(bells, 0)
        XCTAssertEqual(view.viewportCells()[0].prefix(3).joined(), "old")
        feed("\u{1b}[6n\u{07}")
        XCTAssertEqual(sentText, "\u{1b}[1;4R")
        XCTAssertEqual(bells, 1)
    }

    /// The daemon keeps no title; after a re-bind the history is its only source.
    func testReplayedHistoryStillNamesTheTerminal() {
        var titles: [String?] = []
        view.onTitleChanged = { titles.append($0) }
        view.replay(Data("\u{1b}]2;build\u{07}".utf8))
        XCTAssertEqual(titles, ["build"])
    }

    func testTitleChangesReachTheHost() {
        var titles: [String?] = []
        view.onTitleChanged = { titles.append($0) }
        feed("\u{1b}]2;vim\u{07}")
        XCTAssertEqual(titles, ["vim"])
    }
}
