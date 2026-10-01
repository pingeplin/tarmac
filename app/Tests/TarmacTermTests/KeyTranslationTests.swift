import GhosttyVt
import XCTest
@testable import TarmacTerm

final class KeyTranslationTests: XCTestCase {
    func testVirtualKeyCodesMapToPhysicalKeys() {
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x00), GHOSTTY_KEY_A)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x0b), GHOSTTY_KEY_B)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x12), GHOSTTY_KEY_DIGIT_1)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x24), GHOSTTY_KEY_ENTER)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x30), GHOSTTY_KEY_TAB)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x31), GHOSTTY_KEY_SPACE)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x33), GHOSTTY_KEY_BACKSPACE)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x35), GHOSTTY_KEY_ESCAPE)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x75), GHOSTTY_KEY_DELETE)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x7b), GHOSTTY_KEY_ARROW_LEFT)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x7c), GHOSTTY_KEY_ARROW_RIGHT)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x7d), GHOSTTY_KEY_ARROW_DOWN)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x7e), GHOSTTY_KEY_ARROW_UP)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x7a), GHOSTTY_KEY_F1)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0x4c), GHOSTTY_KEY_NUMPAD_ENTER)
        XCTAssertEqual(KeyTranslation.key(forKeyCode: 0xff), GHOSTTY_KEY_UNIDENTIFIED)
    }

    func testModifierFlagsBecomeModsWithSides() {
        let leftShift: UInt = 1 << 17 | 0x02
        let rightShift: UInt = 1 << 17 | 0x04
        let rightOption: UInt = 1 << 19 | 0x40
        XCTAssertEqual(KeyTranslation.mods(rawFlags: leftShift), [.shift])
        XCTAssertEqual(KeyTranslation.mods(rawFlags: rightShift), [.shift, .rightShift])
        XCTAssertEqual(KeyTranslation.mods(rawFlags: rightOption), [.option, .rightOption])
        XCTAssertEqual(KeyTranslation.mods(rawFlags: 1 << 18 | 1 << 20 | 1 << 16), [.control, .command, .capsLock])
    }

    func testControlCharactersAndFunctionKeyScalarsAreNotText() {
        XCTAssertNil(KeyTranslation.text("\u{03}"))
        XCTAssertNil(KeyTranslation.text("\u{7f}"))
        XCTAssertNil(KeyTranslation.text("\u{f700}"))
        XCTAssertNil(KeyTranslation.text(""))
        XCTAssertNil(KeyTranslation.text(nil))
        XCTAssertEqual(KeyTranslation.text("a"), "a")
        XCTAssertEqual(KeyTranslation.text("世"), "世")
    }

    func testTextConsumesShiftAndOptionOnlyWhenItProducedTheCharacter() {
        XCTAssertEqual(KeyTranslation.consumedMods([.shift, .control], text: "A", optionAsAlt: true), [.shift])
        XCTAssertEqual(KeyTranslation.consumedMods([.option], text: "∫", optionAsAlt: false), [.option])
        XCTAssertEqual(KeyTranslation.consumedMods([.option], text: "b", optionAsAlt: true), [])
        XCTAssertEqual(KeyTranslation.consumedMods([.shift], text: nil, optionAsAlt: true), [])
    }
}
