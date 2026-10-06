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

    private func mouse(
        _ type: NSEvent.EventType, col: Int, row: Int, flags: NSEvent.ModifierFlags = [], clicks: Int = 1
    ) throws -> NSEvent {
        let cell = try XCTUnwrap(view.gridLayout).rect(col: col, row: row)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: view.convert(CGPoint(x: cell.midX, y: cell.midY), to: nil), modifierFlags: flags,
            timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
        ))
    }

    private func click(col: Int, row: Int, flags: NSEvent.ModifierFlags = []) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, col: col, row: row, flags: flags))
        view.mouseUp(with: try mouse(.leftMouseUp, col: col, row: row, flags: flags))
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

    /// xterm.js opened a link whatever the program did with the mouse, and
    /// Claude Code's full-screen mode tracks it the whole time.
    func testAClickReportedToAProgramStillOpensTheLink() throws {
        var opened: [String] = []
        view.onOpenLink = { opened.append($0) }
        feed("https://example.com/x now\u{1b}[?1000h\u{1b}[?1006h")
        try click(col: 3, row: 0)
        XCTAssertEqual(opened, ["https://example.com/x"])
        XCTAssertEqual(sentText, "\u{1b}[<0;4;1M\u{1b}[<0;4;1m")
        try click(col: 23, row: 0)
        XCTAssertEqual(opened.count, 1)
    }

    func testClickingEitherRowOfAUrlTheTerminalWrappedOpensAllOfIt() throws {
        var opened: [String] = []
        view.onOpenLink = { opened.append($0) }
        let url = "https://example.com/" + String(repeating: "a", count: view.cols)
        feed("see \(url) now")
        try click(col: 6, row: 0)
        try click(col: 2, row: 1)
        XCTAssertEqual(opened, [url, url])
    }

    /// What the fix is for: Claude Code tracks the mouse and breaks a long
    /// URL over rows itself.
    func testClickingARowOfAUrlAProgramBrokeOpensAllOfIt() throws {
        var opened: [String] = []
        view.onOpenLink = { opened.append($0) }
        let url = "https://example.com/" + String(repeating: "a", count: view.cols)
        let head = String(url.prefix(view.cols - 6))
        feed("\u{1b}[?1000h\u{1b}[?1006h⏺ see \(head)\r\u{1b}[1B  \(url.dropFirst(head.count)) now")
        try click(col: 4, row: 1)
        XCTAssertEqual(opened, [url])
    }

    func testADragReportedToAProgramOpensNoLink() throws {
        var opened: [String] = []
        view.onOpenLink = { opened.append($0) }
        feed("https://example.com/x\u{1b}[?1002h\u{1b}[?1006h")
        view.mouseDown(with: try mouse(.leftMouseDown, col: 3, row: 0))
        view.mouseDragged(with: try mouse(.leftMouseDragged, col: 9, row: 0))
        view.mouseUp(with: try mouse(.leftMouseUp, col: 9, row: 0))
        XCTAssertEqual(opened, [])

        view.mouseDown(with: try mouse(.leftMouseDown, col: 3, row: 0))
        view.mouseDragged(with: try mouse(.leftMouseDragged, col: 9, row: 0))
        view.mouseDragged(with: try mouse(.leftMouseDragged, col: 3, row: 0))
        view.mouseUp(with: try mouse(.leftMouseUp, col: 3, row: 0))
        XCTAssertEqual(opened, [])

        view.mouseDown(with: try mouse(.leftMouseDown, col: 3, row: 0))
        view.mouseUp(with: try mouse(.leftMouseUp, col: 9, row: 0))
        XCTAssertEqual(opened, [])

        view.mouseDown(with: try mouse(.leftMouseDown, col: 3, row: 0))
        view.mouseDragged(with: try mouse(.leftMouseDragged, col: 9, row: 0, flags: .option))
        view.mouseDragged(with: try mouse(.leftMouseDragged, col: 3, row: 0, flags: .option))
        view.mouseUp(with: try mouse(.leftMouseUp, col: 3, row: 0))
        XCTAssertEqual(opened, [])
    }

    func testADoubleClickReportedToAProgramOpensTheLinkOnce() throws {
        var opened: [String] = []
        view.onOpenLink = { opened.append($0) }
        feed("https://example.com/x\u{1b}[?1000h\u{1b}[?1006h")
        try click(col: 3, row: 0)
        view.mouseDown(with: try mouse(.leftMouseDown, col: 3, row: 0, clicks: 2))
        view.mouseUp(with: try mouse(.leftMouseUp, col: 3, row: 0, clicks: 2))
        XCTAssertEqual(opened, ["https://example.com/x"])
    }

    /// The program may redraw on the press, and what is under the pointer at
    /// the release is then not what was clicked.
    func testALinkDrawnUnderAHeldPressIsNotOpened() throws {
        var opened: [String] = []
        view.onOpenLink = { opened.append($0) }
        feed("https://example.com/x\u{1b}[?1000h\u{1b}[?1006h")
        view.mouseDown(with: try mouse(.leftMouseDown, col: 3, row: 0))
        feed("\r\u{1b}[2Khttps://example.com/other")
        view.mouseUp(with: try mouse(.leftMouseUp, col: 3, row: 0))
        XCTAssertEqual(opened, [])

        feed("\r\u{1b}[2Kplain text, no link")
        view.mouseDown(with: try mouse(.leftMouseDown, col: 3, row: 0))
        feed("\r\u{1b}[2Khttps://example.com/x")
        view.mouseUp(with: try mouse(.leftMouseUp, col: 3, row: 0))
        XCTAssertEqual(opened, [])
    }

    /// Claude Code opens a URL itself when the click reports ⌃, so the terminal
    /// opening it too would open it twice.
    func testAControlOrShiftClickReportedToAProgramIsItsAlone() throws {
        var opened: [String] = []
        view.onOpenLink = { opened.append($0) }
        feed("https://example.com/x\u{1b}[?1000h\u{1b}[?1006h")
        try click(col: 3, row: 0, flags: .control)
        try click(col: 3, row: 0, flags: .shift)
        XCTAssertEqual(opened, [])
        XCTAssertEqual(sentText, "\u{1b}[<16;4;1M\u{1b}[<16;4;1m\u{1b}[<4;4;1M\u{1b}[<4;4;1m")

        view.mouseDown(with: try mouse(.leftMouseDown, col: 3, row: 0, flags: .control))
        view.mouseUp(with: try mouse(.leftMouseUp, col: 3, row: 0))
        XCTAssertEqual(opened, [])
        view.mouseDown(with: try mouse(.leftMouseDown, col: 3, row: 0))
        view.mouseUp(with: try mouse(.leftMouseUp, col: 3, row: 0, flags: .control))
        XCTAssertEqual(opened, [])
    }

    func testTheHandShowsOverALinkWhoeverGetsTheClick() throws {
        feed("see https://example.com/x now")
        view.mouseMoved(with: try mouse(.mouseMoved, col: 6, row: 0))
        XCTAssertEqual(NSCursor.current, .pointingHand)
        view.mouseMoved(with: try mouse(.mouseMoved, col: 1, row: 0))
        XCTAssertEqual(NSCursor.current, .iBeam)

        feed("\u{1b}[?1000h\u{1b}[?1006h")
        view.mouseMoved(with: try mouse(.mouseMoved, col: 6, row: 0))
        XCTAssertEqual(NSCursor.current, .pointingHand)
        view.mouseMoved(with: try mouse(.mouseMoved, col: 6, row: 0, flags: .control))
        XCTAssertEqual(NSCursor.current, .iBeam)
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
    /// density would spawn at one size and correct it on mount. Menlo is
    /// named because the system face has one cell at both densities.
    func testAnUnwindowedViewMeasuresItsGridAtTheGivenBackingScale() throws {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let cells = try [1, 2].map { scale -> CGSize? in
            let view = try TerminalView(frame: frame, fontFamily: "Menlo", backingScale: scale)
            XCTAssertEqual(view.gridLayout?.cell, cell("Menlo", scale: scale))
            return view.gridLayout?.cell
        }
        XCTAssertNotEqual(cells[0], cells[1])
    }

    // MARK: the chosen family (2610.0005)

    private func cell(_ family: String?, size: CGFloat = 16, scale: CGFloat? = nil) -> CGSize {
        TerminalFonts(size: size, pixelsPerPoint: scale ?? window.backingScaleFactor, family: family).metrics.cell
    }

    /// S12 — a new family is a new cell: the grid is laid out again and the
    /// program is told its new size, once.
    func testANewFamilyRebuildsTheFontsAndReportsTheNewGrid() throws {
        XCTAssertNotEqual(cell("Monaco"), cell(nil))
        let before = view.fontGeneration

        view.fontFamily = "Monaco"

        XCTAssertEqual(view.fontGeneration, before + 1)
        XCTAssertEqual(view.gridLayout?.cell, cell("Monaco"))
        let layout = try XCTUnwrap(TerminalGridLayout(
            bounds: view.bounds.size, cell: cell("Monaco"), padding: view.padding
        ))
        XCTAssertEqual(resizes, [[layout.cols, layout.rows]])
        XCTAssertEqual([view.engine.cols, view.engine.rows], [layout.cols, layout.rows])
    }

    /// S32
    func testTheSameFamilyAgainDoesNothingAndNoFamilyIsTheSystemFace() {
        view.fontFamily = "Monaco"
        let before = view.fontGeneration
        resizes = []

        view.fontFamily = "Monaco"
        XCTAssertEqual(view.fontGeneration, before)
        XCTAssertEqual(resizes, [])

        view.fontFamily = nil
        XCTAssertEqual(view.fontGeneration, before + 1)
        XCTAssertEqual(view.gridLayout?.cell, cell(nil))
        XCTAssertEqual(resizes.count, 1)
    }

    /// S33 — a rebuild for a new display density keeps the chosen family.
    func testARebuildForANewBackingScaleKeepsTheFamily() throws {
        let mounted = window.backingScaleFactor
        let other: CGFloat = mounted == 1 ? 2 : 1
        let view = try TerminalView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), fontFamily: "Monaco", backingScale: other
        )
        XCTAssertEqual(view.gridLayout?.cell, cell("Monaco", scale: other))
        let before = view.fontGeneration

        window.contentView?.addSubview(view)

        XCTAssertEqual(view.fontGeneration, before + 1)
        XCTAssertEqual(view.gridLayout?.cell, cell("Monaco", scale: mounted))
        XCTAssertNotEqual(view.gridLayout?.cell, cell(nil, scale: mounted))
    }

    // MARK: the chosen size (2610.0006)

    /// S11 — a new size is a new cell: the grid is laid out again in the same
    /// view and the program is told its new size, once.
    func testANewSizeRebuildsTheFontsAndReportsTheNewGrid() throws {
        XCTAssertNotEqual(cell(nil, size: 20), cell(nil))
        let before = view.fontGeneration

        view.fontSize = 20

        XCTAssertEqual(view.fontGeneration, before + 1)
        XCTAssertEqual(view.gridLayout?.cell, cell(nil, size: 20))
        let layout = try XCTUnwrap(TerminalGridLayout(
            bounds: view.bounds.size, cell: cell(nil, size: 20), padding: view.padding
        ))
        XCTAssertEqual(resizes, [[layout.cols, layout.rows]])
        XCTAssertEqual([view.engine.cols, view.engine.rows], [layout.cols, layout.rows])
    }

    /// S11 — a smaller size is a new cell too.
    func testASmallerSizeRebuildsTheFonts() {
        XCTAssertNotEqual(cell(nil), cell(nil, size: 20))
        view.fontSize = 20
        let before = view.fontGeneration

        view.fontSize = 16

        XCTAssertEqual(view.fontGeneration, before + 1)
        XCTAssertEqual(view.gridLayout?.cell, cell(nil))
    }

    /// S26
    func testTheSameSizeAgainDoesNothing() {
        view.fontSize = 20
        let before = view.fontGeneration
        resizes = []

        view.fontSize = 20

        XCTAssertEqual(view.fontGeneration, before)
        XCTAssertEqual(resizes, [])
    }

    /// S27 — the size and the family are two choices: a change of one keeps
    /// the other.
    func testANewSizeKeepsTheFamilyAndANewFamilyKeepsTheSize() {
        let monacoAt20 = cell("Monaco", size: 20)
        XCTAssertNotEqual(monacoAt20, cell("Monaco"))
        XCTAssertNotEqual(monacoAt20, cell(nil, size: 20))

        view.fontFamily = "Monaco"
        view.fontSize = 20
        XCTAssertEqual(view.gridLayout?.cell, monacoAt20)

        view.fontFamily = nil
        XCTAssertEqual(view.gridLayout?.cell, cell(nil, size: 20))
        view.fontFamily = "Monaco"
        XCTAssertEqual(view.gridLayout?.cell, monacoAt20)
    }

    /// S28 — a rebuild for a new display density keeps the chosen size. The
    /// system face is used because Monaco's cell at 20 is one at both
    /// densities.
    func testARebuildForANewBackingScaleKeepsTheSize() throws {
        let mounted = window.backingScaleFactor
        let other: CGFloat = mounted == 1 ? 2 : 1
        XCTAssertNotEqual(cell(nil, size: 20, scale: mounted), cell(nil, size: 20, scale: other))
        XCTAssertNotEqual(cell(nil, size: 20, scale: mounted), cell(nil, scale: mounted))
        let view = try TerminalView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400), fontSize: 20, backingScale: other
        )
        XCTAssertEqual(view.gridLayout?.cell, cell(nil, size: 20, scale: other))
        let before = view.fontGeneration

        window.contentView?.addSubview(view)

        XCTAssertEqual(view.fontGeneration, before + 1)
        XCTAssertEqual(view.gridLayout?.cell, cell(nil, size: 20, scale: mounted))
    }

    /// A rebuild for a new size keeps the display density the view was built
    /// at. The view is in no window, so that density is not the mounted one.
    func testANewSizeKeepsTheBackingScale() throws {
        let mounted = window.backingScaleFactor
        let other: CGFloat = mounted == 1 ? 2 : 1
        XCTAssertNotEqual(cell(nil, size: 20, scale: other), cell(nil, size: 20, scale: mounted))
        let view = try TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), backingScale: other)

        view.fontSize = 20

        XCTAssertEqual(view.gridLayout?.cell, cell(nil, size: 20, scale: other))
    }

    // MARK: the theme of a live view (2610.0007)

    private let dark = TerminalTheme.breeze

    /// No colour of it is Breeze's, ANSI 1 too, which Breeze Light keeps.
    private let light = TerminalTheme(
        foreground: RGB(hex: 0x232629), background: RGB(hex: 0xfcfcfc), cursor: RGB(hex: 0x7a3e9d),
        selection: RGB(hex: 0x12846e), selectionAlpha: 0.5,
        ansi: [
            0x1b1e20, 0xa01010, 0x0b8a0f, 0xbe5a00, 0x2980b9, 0x7d3c98, 0x12846e, 0x63686d,
            0x5f6b6c, 0x922b21, 0x11865e, 0xa36802, 0x147db3, 0x6c3483, 0x117864, 0x232629,
        ].map(RGB.init(hex:))
    )

    /// What `view` draws now, to sample by cell. A draw reads no frame.
    private func drawn(_ view: TerminalView) throws -> Canvas {
        let canvas = try Canvas(
            size: view.bounds.size, scale: 2, fill: RGB(255, 0, 255), layout: try XCTUnwrap(view.gridLayout)
        )
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas.context, flipped: true)
        view.draw(view.bounds)
        return canvas
    }

    /// S21 — the frame is not read again after the change, and a draw reads
    /// none: the second bitmap has the new colours only if the setter read one.
    func test2610_0007S21ANewThemeRecoloursTheTextOnScreenWithNothingFed() throws {
        feed("MMMM\r\n\u{1b}[31mMMMM\u{1b}[0m\r\n\u{1b}[44m    \u{1b}[0m")
        read()
        let before = try drawn(view)
        XCTAssertTrue(before.colours(inCols: 0..<4, row: 0).contains(dark.foreground))
        XCTAssertTrue(before.colours(inCols: 0..<4, row: 1).contains(dark.ansi[1]))
        XCTAssertEqual(before.colours(inCols: 0..<4, row: 2), [dark.ansi[4]])
        let grid = [view.cols, view.rows]

        view.theme = light

        let after = try drawn(view)
        XCTAssertTrue(after.colours(inCols: 0..<4, row: 0).contains(light.foreground))
        let red = after.colours(inCols: 0..<4, row: 1)
        XCTAssertTrue(red.contains(light.ansi[1]))
        XCTAssertFalse(red.contains(dark.ansi[1]))
        XCTAssertEqual(after.colours(inCols: 0..<4, row: 2), [light.ansi[4]])
        XCTAssertEqual([view.cols, view.rows], grid)
        XCTAssertEqual(resizes, [])
    }

    /// The exception of S21: while a program holds its output (mode 2026) the
    /// frame on screen stays, and the new colours come when the hold ends.
    func test2610_0007ANewThemeWaitsForAHeldFrame() throws {
        feed("\u{1b}[?2026h")

        view.theme = light

        XCTAssertEqual(try drawn(view).center(col: 10, row: 5), dark.background)
        feed("\u{1b}[?2026l")
        read()
        XCTAssertEqual(try drawn(view).center(col: 10, row: 5), light.background)
    }

    /// S22 — the window is not key, so the cursor is an outline.
    func test2610_0007S22ANewThemeRecoloursTheBackgroundAndTheCursor() throws {
        feed("ab")
        read()
        XCTAssertTrue(try drawn(view).colours(inCols: 2..<3, row: 0).contains(dark.cursor))

        view.theme = light

        let canvas = try drawn(view)
        XCTAssertEqual(canvas.center(col: 10, row: 5), light.background)
        let cursor = canvas.colours(inCols: 2..<3, row: 0)
        XCTAssertTrue(cursor.contains(light.cursor))
        XCTAssertFalse(cursor.contains(dark.cursor))
    }

    /// S22
    func test2610_0007S22ASelectionMadeBeforeTheChangeTakesTheNewTint() throws {
        view.mouseDown(with: try mouse(.leftMouseDown, col: 2, row: 3))
        view.mouseDragged(with: try mouse(.leftMouseDragged, col: 8, row: 3))
        view.mouseUp(with: try mouse(.leftMouseUp, col: 8, row: 3))
        read()
        XCTAssertEqual(
            try drawn(view).center(col: 5, row: 3),
            dark.background.blended(with: dark.selection, alpha: dark.selectionAlpha)
        )

        view.theme = light

        XCTAssertEqual(
            try drawn(view).center(col: 5, row: 3),
            light.background.blended(with: light.selection, alpha: light.selectionAlpha)
        )
    }

    private let colourQueries = "\u{1b}]11;?\u{1b}\\\u{1b}]10;?\u{1b}\\\u{1b}]4;2;?\u{1b}\\\u{1b}[?996n"
    private let lightAnswers = "\u{1b}]11;rgb:fcfc/fcfc/fcfc\u{1b}\\\u{1b}]10;rgb:2323/2626/2929\u{1b}\\"
        + "\u{1b}]4;2;rgb:0b0b/8a8a/0f0f\u{1b}\\\u{1b}[?997;2n"

    /// S23
    func test2610_0007S23ColourQueriesAreAnsweredFromTheThemeSetLater() {
        view.theme = light

        feed(colourQueries)

        XCTAssertEqual(sentText, lightAnswers)
    }

    /// S23 — and each terminal answers for its own theme: the suite's view,
    /// made before this one, is still dark.
    func test2610_0007S23ColourQueriesAreAnsweredFromTheThemeGivenAtInit() throws {
        let view = try TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), theme: light)
        var sent: [UInt8] = []
        view.onInput = { sent.append(contentsOf: $0) }

        view.feed(Data(colourQueries.utf8))
        feed("\u{1b}[?996n")

        XCTAssertEqual(String(decoding: sent, as: UTF8.self), lightAnswers)
        XCTAssertEqual(sentText, "\u{1b}[?997;1n")
    }

    /// S23
    func test2610_0007S23ADarkThemeAnswersTheColourSchemeQueryAsDark() {
        feed("\u{1b}[?996n")

        XCTAssertEqual(sentText, "\u{1b}[?997;1n")
    }

    /// S24
    func test2610_0007S24AProgramThatAskedIsToldOnceEachTimeTheSchemeChanges() {
        feed("\u{1b}[?2031h")

        view.theme = light
        XCTAssertEqual(sentText, "\u{1b}[?997;2n")

        sent = []
        view.theme = dark
        XCTAssertEqual(sentText, "\u{1b}[?997;1n")
    }

    /// S43
    func test2610_0007S43AProgramThatDidNotAskIsToldNothing() {
        view.theme = light

        XCTAssertEqual(view.theme, light)
        XCTAssertEqual(sent, [])
    }

    /// S43
    func test2610_0007S43AnotherThemeOfTheSameSchemeIsNotReported() {
        var darker = dark
        darker.background = RGB(hex: 0x101214)
        feed("\u{1b}[?2031h")

        view.theme = darker

        XCTAssertEqual(view.theme, darker)
        XCTAssertEqual(sent, [])
    }

    /// S43
    func test2610_0007S43TheThemeTheViewAlreadyHasIsNotReported() {
        feed("\u{1b}[?2031h")

        view.theme = dark

        XCTAssertEqual(sent, [])
    }

    /// A draw reads no frame: output that was fed and not read yet shows only
    /// if the setter read one.
    func test2610_0007TheThemeTheViewAlreadyHasReadsNoFrame() throws {
        feed("\r\nMMMM")

        view.theme = dark

        XCTAssertEqual(try drawn(view).colours(inCols: 0..<4, row: 1), [dark.background])
    }

    /// S43
    func test2610_0007S43AProgramThatStoppedAskingIsToldNothing() {
        feed("\u{1b}[?2031h\u{1b}[?2031l")

        view.theme = light

        XCTAssertEqual(view.theme, light)
        XCTAssertEqual(sent, [])
    }

    /// S25 — a rebuild of the fonts makes a new renderer.
    func test2610_0007S25TheThemeSetLaterSurvivesANewFamilyAndANewSize() throws {
        view.theme = light
        let before = view.fontGeneration

        view.fontFamily = "Monaco"
        view.fontSize = 20

        XCTAssertEqual(view.fontGeneration, before + 2)
        XCTAssertEqual(view.theme, light)
        XCTAssertEqual(try drawn(view).center(col: 10, row: 5), light.background)
    }

    /// S25
    func test2610_0007S25TheThemeSetLaterSurvivesARebuildForANewBackingScale() throws {
        let mounted = window.backingScaleFactor
        let other: CGFloat = mounted == 1 ? 2 : 1
        let view = try TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), backingScale: other)
        view.theme = light
        let before = view.fontGeneration

        window.contentView?.addSubview(view)

        XCTAssertEqual(view.fontGeneration, before + 1)
        XCTAssertEqual(view.theme, light)
        XCTAssertEqual(try drawn(view).center(col: 10, row: 5), light.background)
    }

    /// S44 — a 256-colour index above 15 and an RGB colour are not the
    /// theme's to change.
    func test2610_0007S44ANewThemeLeavesIndexedAndRgbTextAsItWas() throws {
        let indexed = RGB(255, 0, 0), direct = RGB(10, 20, 30)
        feed("\u{1b}[38;5;196mMMMM\u{1b}[0m\r\n\u{1b}[38;2;10;20;30mMMMM\u{1b}[0m")
        read()
        let before = try drawn(view)
        XCTAssertTrue(before.colours(inCols: 0..<4, row: 0).contains(indexed))
        XCTAssertTrue(before.colours(inCols: 0..<4, row: 1).contains(direct))

        view.theme = light

        let after = try drawn(view)
        XCTAssertEqual(after.center(col: 10, row: 5), light.background)
        XCTAssertTrue(after.colours(inCols: 0..<4, row: 0).contains(indexed))
        XCTAssertTrue(after.colours(inCols: 0..<4, row: 1).contains(direct))
    }

    /// S44 — a colour the program set is its own until it gives it back.
    func test2610_0007S44AProgramsOwnBackgroundOutlivesANewThemeUntilItIsReset() throws {
        feed("\u{1b}]11;rgb:10/20/30\u{1b}\\")
        read()

        view.theme = light

        XCTAssertEqual(try drawn(view).center(col: 10, row: 5), RGB(hex: 0x102030))
        feed("\u{1b}]111\u{1b}\\")
        read()
        XCTAssertEqual(try drawn(view).center(col: 10, row: 5), light.background)
    }

    // MARK: a default colour a program sets, on screen (2610.0007 S50)

    /// S50 — a default colour changes no row, so the frame read names none
    /// dirty, and an empty cell has no colour of its own: it shows the new
    /// background only if the view asked for every row to be drawn again.
    /// The cursor is on row 0.
    func test2610_0007S50AProgramsOwnBackgroundReachesTheRowsItDidNotWrite() throws {
        feed("ab")
        settle()
        let screen = try Screen(showing: view)
        XCTAssertEqual(screen.shown().center(col: 10, row: 5), dark.background)

        feed("\u{1b}]11;rgb:10/20/30\u{1b}\\")
        settle()
        XCTAssertEqual(screen.shown().center(col: 10, row: 5), RGB(hex: 0x102030))

        feed("\u{1b}]111\u{1b}\\")
        settle()
        XCTAssertEqual(screen.shown().center(col: 10, row: 5), dark.background)
    }

    /// S50, for the foreground: text with no colour of its own. The cursor is
    /// on row 2.
    func test2610_0007S50AProgramsOwnForegroundReachesTheTextAlreadyOnScreen() throws {
        let own = RGB(hex: 0xaabbcc)
        feed("MMMM\r\n\r\n")
        settle()
        let screen = try Screen(showing: view)
        XCTAssertTrue(screen.shown().colours(inCols: 0..<4, row: 0).contains(dark.foreground))

        feed("\u{1b}]10;rgb:aa/bb/cc\u{1b}\\")
        settle()
        let set = screen.shown().colours(inCols: 0..<4, row: 0)
        XCTAssertTrue(set.contains(own))
        XCTAssertFalse(set.contains(dark.foreground))

        feed("\u{1b}]110\u{1b}\\")
        settle()
        let reset = screen.shown().colours(inCols: 0..<4, row: 0)
        XCTAssertTrue(reset.contains(dark.foreground))
        XCTAssertFalse(reset.contains(own))
    }

    /// The cost: a frame that changes no default colour draws its own rows
    /// and no more.
    func test2610_0007S50AnOrdinaryFrameDrawsOnlyItsRows() throws {
        feed("ab\r\n")
        settle()
        let screen = try Screen(showing: view)
        _ = screen.shown()

        feed("x")
        settle()
        _ = screen.shown()
        XCTAssertEqual(screen.asked, [view.damageRect(forRow: 1)])

        feed("\u{1b}]11;rgb:10/20/30\u{1b}\\")
        settle()
        _ = screen.shown()
        XCTAssertEqual(screen.asked.map { $0.intersection(view.bounds) }, [view.bounds])

        feed("y")
        settle()
        _ = screen.shown()
        XCTAssertEqual(screen.asked, [view.damageRect(forRow: 1)])
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

/// A stand-in for the screen, which `drawn(_:)` is not: that draws every row,
/// whatever the view asked for. This keeps what was drawn before and, when
/// the view is displayed, draws again only the rects AppKit then asks it to
/// draw: the ones the view marked. `TerminalView` is final, so those rects
/// are seen from a subclass made at run time, which draws as it does.
@MainActor
private final class Screen {
    private let view: TerminalView
    private let canvas: Canvas
    /// What AppKit asked the view to draw when it was last shown.
    private(set) var asked: [NSRect] = []
    private var recorded: [NSRect] = []

    init(showing view: TerminalView) throws {
        self.view = view
        canvas = try Canvas(
            size: view.bounds.size, scale: 2, fill: RGB(255, 0, 255), layout: try XCTUnwrap(view.gridLayout)
        )
        let draw = #selector(NSView.draw(_:))
        let method = try XCTUnwrap(class_getInstanceMethod(TerminalView.self, draw))
        let inherited = unsafeBitCast(
            method_getImplementation(method), to: (@convention(c) (NSView, Selector, NSRect) -> Void).self
        )
        let recording: @convention(block) (NSView, NSRect) -> Void = { [unowned self] view, rect in
            self.recorded.append(rect)
            inherited(view, draw, rect)
        }
        let subclass: AnyClass = try XCTUnwrap(
            objc_allocateClassPair(TerminalView.self, "TerminalViewOnScreen\(UUID().uuidString)", 0)
        )
        class_addMethod(subclass, draw, imp_implementationWithBlock(recording), method_getTypeEncoding(method))
        objc_registerClassPair(subclass)
        object_setClass(view, subclass)
    }

    /// Displays the view, and gives what the screen holds then.
    func shown() -> Canvas {
        recorded = []
        view.displayIfNeeded()
        asked = recorded
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas.context, flipped: true)
        for rect in asked {
            canvas.context.saveGState()
            canvas.context.clip(to: rect)
            view.draw(rect)
            canvas.context.restoreGState()
        }
        return canvas
    }
}
