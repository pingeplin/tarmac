import GhosttyVt
import XCTest
@testable import TarmacTerm

@MainActor
final class TerminalInputTests: XCTestCase {
    private func engine(cols: Int = 20, rows: Int = 4) throws -> TerminalEngine {
        try TerminalEngine(cols: cols, rows: rows)
    }

    private func feed(_ engine: TerminalEngine, _ text: String) {
        engine.feed(Array(text.utf8))
    }

    private func sent(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private func letter(_ key: GhosttyKey, _ character: Character, mods: KeyMods = []) -> KeyInput {
        KeyInput(key: key, mods: mods, text: String(character), unshiftedCodepoint: character.unicodeScalars.first!.value)
    }

    // MARK: keys

    func testPrintableKeySendsItsText() throws {
        XCTAssertEqual(sent(try engine().encode(letter(GHOSTTY_KEY_A, "a"))), "a")
    }

    func testShiftedKeySendsTheProducedCharacter() throws {
        let input = KeyInput(
            key: GHOSTTY_KEY_DIGIT_1, mods: .shift, consumedMods: .shift, text: "!", unshiftedCodepoint: 0x31
        )
        XCTAssertEqual(sent(try engine().encode(input)), "!")
    }

    func testControlLetterSendsItsC0Code() throws {
        XCTAssertEqual(try engine().encode(letter(GHOSTTY_KEY_C, "c", mods: .control)), [0x03])
    }

    func testFunctionalKeysUseLegacyEncodings() throws {
        let engine = try engine()
        XCTAssertEqual(engine.encode(KeyInput(key: GHOSTTY_KEY_ENTER)), [0x0d])
        XCTAssertEqual(engine.encode(KeyInput(key: GHOSTTY_KEY_BACKSPACE)), [0x7f])
        XCTAssertEqual(engine.encode(KeyInput(key: GHOSTTY_KEY_ESCAPE)), [0x1b])
        XCTAssertEqual(engine.encode(KeyInput(key: GHOSTTY_KEY_TAB)), [0x09])
        XCTAssertEqual(sent(engine.encode(KeyInput(key: GHOSTTY_KEY_TAB, mods: .shift))), "\u{1b}[Z")
        XCTAssertEqual(sent(engine.encode(KeyInput(key: GHOSTTY_KEY_DELETE))), "\u{1b}[3~")
    }

    func testArrowKeysFollowCursorKeyMode() throws {
        let engine = try engine()
        XCTAssertEqual(sent(engine.encode(KeyInput(key: GHOSTTY_KEY_ARROW_UP))), "\u{1b}[A")
        feed(engine, "\u{1b}[?1h")
        XCTAssertEqual(sent(engine.encode(KeyInput(key: GHOSTTY_KEY_ARROW_UP))), "\u{1b}OA")
    }

    func testOptionActsAsAltByDefault() throws {
        let engine = try engine()
        XCTAssertEqual(sent(engine.encode(letter(GHOSTTY_KEY_B, "b", mods: .option))), "\u{1b}b")
        engine.optionAsAlt = false
        XCTAssertEqual(
            sent(engine.encode(KeyInput(key: GHOSTTY_KEY_B, mods: .option, consumedMods: .option, text: "∫", unshiftedCodepoint: 0x62))),
            "∫"
        )
    }

    func testKeysTheImeConsumedSendNothing() throws {
        let engine = try engine()
        XCTAssertEqual(engine.encode(KeyInput(key: GHOSTTY_KEY_SPACE, text: " ", unshiftedCodepoint: 0x20, composing: true)), [])
        XCTAssertEqual(engine.encode(KeyInput(key: GHOSTTY_KEY_BACKSPACE, composing: true)), [])
        XCTAssertEqual(engine.encode(KeyInput(key: GHOSTTY_KEY_ENTER, composing: true)), [])
        XCTAssertEqual(engine.encode(KeyInput(key: GHOSTTY_KEY_ARROW_LEFT, composing: true)), [])
        feed(engine, "\u{1b}[>1u")
        XCTAssertEqual(engine.encode(KeyInput(key: GHOSTTY_KEY_ESCAPE, composing: true)), [])
    }

    func testKeyReleaseIsSilentInLegacyMode() throws {
        XCTAssertEqual(try engine().encode(KeyInput(action: .release, key: GHOSTTY_KEY_A)), [])
    }

    func testKittyProtocolDisambiguatesOnceTheProgramEnablesIt() throws {
        let engine = try engine()
        feed(engine, "\u{1b}[>1u")
        XCTAssertEqual(sent(engine.encode(letter(GHOSTTY_KEY_C, "c", mods: .control))), "\u{1b}[99;5u")
        XCTAssertEqual(sent(engine.encode(KeyInput(key: GHOSTTY_KEY_ESCAPE))), "\u{1b}[27u")
    }

    func testKittyProtocolReportsReleasesWhenAsked() throws {
        let engine = try engine()
        feed(engine, "\u{1b}[>3u")
        XCTAssertEqual(sent(engine.encode(KeyInput(action: .release, key: GHOSTTY_KEY_ESCAPE))), "\u{1b}[27;1:3u")
    }

    // MARK: mouse

    private let surface = SurfaceGeometry(width: 200, height: 80, cellWidth: 10, cellHeight: 20)

    func testMouseIsSilentUntilTheProgramTracksIt() throws {
        let press = MouseInput(action: .press, button: .left, x: 25, y: 30)
        XCTAssertEqual(try engine().encode(press, surface: surface), [])
    }

    func testSgrMouseReportsOneBasedCells() throws {
        let engine = try engine()
        feed(engine, "\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertEqual(
            sent(engine.encode(MouseInput(action: .press, button: .left, x: 25, y: 30), surface: surface)),
            "\u{1b}[<0;3;2M"
        )
        XCTAssertEqual(
            sent(engine.encode(MouseInput(action: .release, button: .left, x: 25, y: 30), surface: surface)),
            "\u{1b}[<0;3;2m"
        )
    }

    func testWheelIsReportedAsButtonsFourAndFive() throws {
        let engine = try engine()
        feed(engine, "\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertEqual(
            sent(engine.encode(MouseInput(action: .press, button: .wheelUp, x: 5, y: 5), surface: surface)),
            "\u{1b}[<64;1;1M"
        )
        XCTAssertEqual(
            sent(engine.encode(MouseInput(action: .press, button: .wheelDown, x: 5, y: 5), surface: surface)),
            "\u{1b}[<65;1;1M"
        )
    }

    func testMotionIsReportedOnlyUnderAnyEventTracking() throws {
        let engine = try engine()
        feed(engine, "\u{1b}[?1000h\u{1b}[?1006h")
        let motion = MouseInput(action: .motion, button: nil, x: 25, y: 30)
        XCTAssertEqual(engine.encode(motion, surface: surface), [])
        feed(engine, "\u{1b}[?1003h")
        XCTAssertEqual(sent(engine.encode(motion, surface: surface)), "\u{1b}[<35;3;2M")
    }
}
