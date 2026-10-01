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

    func testOutputIsReadableBack() {
        feed("hello")
        XCTAssertEqual(view.plainText(), "hello")
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

    func testNamedKeysAreEncoded() {
        view.keyDown(with: key("\r", code: 0x24))
        view.keyDown(with: key("\u{f700}", code: 0x7e, flags: [.function, .numericPad]))
        XCTAssertEqual(sentText, "\r\u{1b}[A")
    }

    func testOptionKeySendsMetaPrefix() {
        view.keyDown(with: key("∫", code: 0x0b, flags: .option, unmodified: "b"))
        XCTAssertEqual(sentText, "\u{1b}b")
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

    func testWheelOnTheAlternateScreenSendsArrowKeys() throws {
        feed("\u{1b}[?1049h")
        view.scrollWheel(with: try wheel(lines: -1))
        XCTAssertEqual(sentText, "\u{1b}[B")
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

    // MARK: focus

    func testFocusChangesAreReportedWhenTheProgramAsks() {
        feed("\u{1b}[?1004h")
        window.makeFirstResponder(nil)
        window.makeFirstResponder(view)
        XCTAssertEqual(sentText, "\u{1b}[O\u{1b}[I")
    }

    // MARK: program replies

    func testQueriesAreAnsweredThroughTheInputPath() {
        feed("\u{1b}[6n")
        XCTAssertEqual(sentText, "\u{1b}[1;1R")
    }

    func testTitleChangesReachTheHost() {
        var titles: [String?] = []
        view.onTitleChanged = { titles.append($0) }
        feed("\u{1b}]2;vim\u{07}")
        XCTAssertEqual(titles, ["vim"])
    }
}
