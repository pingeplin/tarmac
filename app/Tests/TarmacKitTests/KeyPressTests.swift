import XCTest
@testable import TarmacKit

/// The key facts every app-level key table reads (parity rows K6–K9, S9).
final class KeyPressTests: XCTestCase {
    private let capsLock: UInt = 1 << 16
    private let shift: UInt = 1 << 17
    private let control: UInt = 1 << 18
    private let option: UInt = 1 << 19
    private let command: UInt = 1 << 20
    private let numericPad: UInt = 1 << 21
    private let function: UInt = 1 << 23

    private func press(
        _ keyCode: UInt16, _ characters: String, ignoring: String? = nil, _ mods: UInt = 0
    ) -> KeyPress {
        KeyPress(
            keyCode: keyCode, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
            modifierFlags: mods
        )
    }

    // MARK: modifiers

    func testReadsTheFourIntentModifiers() {
        let p = press(0x28, "k", command | shift)
        XCTAssertTrue(p.command)
        XCTAssertTrue(p.shift)
        XCTAssertFalse(p.option)
        XCTAssertFalse(p.control)
        let q = press(0x30, "\t", option | control)
        XCTAssertTrue(q.option)
        XCTAssertTrue(q.control)
        XCTAssertFalse(q.command)
        XCTAssertFalse(q.shift)
    }

    // MARK: named keys

    func testNamedKeysAreThePhysicalKeys() {
        XCTAssertEqual(press(53, "\u{1b}").named, .escape)
        XCTAssertEqual(press(36, "\r").named, .enter)
        XCTAssertEqual(press(48, "\t").named, .tab)
        XCTAssertEqual(press(51, "\u{7f}").named, .backspace)
        XCTAssertEqual(press(126, "\u{F700}", function | numericPad).named, .arrowUp)
        XCTAssertEqual(press(125, "\u{F701}", function | numericPad).named, .arrowDown)
    }

    /// The keypad's Enter is `Enter` to the web app too.
    func testKeypadEnterIsEnter() {
        XCTAssertEqual(press(76, "\u{3}", numericPad).named, .enter)
    }

    func testOtherKeysAreNotNamed() {
        XCTAssertNil(press(0x28, "k").named)
        XCTAssertNil(press(123, "\u{F702}", function | numericPad).named, "←")
        XCTAssertNil(press(117, "\u{F728}", function).named, "forward delete is not Backspace")
    }

    // MARK: key

    /// WebKit's `KeyboardEvent.key`: the characters the press produced, except
    /// under control, where it is the character without the modifiers.
    func testKeyIsTheProducedCharacters() {
        XCTAssertEqual(press(0x28, "k", ignoring: "k", command).key, "k")
        XCTAssertEqual(press(0x00, "A", ignoring: "A", shift).key, "A")
        XCTAssertEqual(press(0x00, "å", ignoring: "a", option).key, "å")
    }

    func testKeyUnderControlIgnoresTheModifiers() {
        XCTAssertEqual(press(0x00, "\u{1}", ignoring: "a", control).key, "a")
    }

    // MARK: command chords

    func testCommandChordMatchesTheProducedLetter() {
        XCTAssertTrue(press(0x28, "k", command).isCommandChord("k"))
        XCTAssertFalse(press(0x28, "k", command).isCommandChord("w"))
    }

    /// A layout that puts another letter on the physical K key: the letter
    /// decides, not the key.
    func testCommandChordFollowsTheLayoutNotThePhysicalKey() {
        XCTAssertTrue(press(0x09, "k", command).isCommandChord("k"), "Dvorak K is on the QWERTY V key")
        XCTAssertFalse(press(0x28, "t", command).isCommandChord("k"), "the QWERTY K key types T on Dvorak")
    }

    func testCommandChordIgnoresLetterCase() {
        XCTAssertTrue(press(0x28, "K", command | shift).isCommandChord("k"))
    }

    func testCommandChordAllowsShiftAndCapsLock() {
        XCTAssertTrue(press(0x28, "k", command | shift).isCommandChord("k"))
        XCTAssertTrue(press(0x28, "k", command | capsLock).isCommandChord("k"))
    }

    func testCommandChordRefusesOptionAndControl() {
        XCTAssertFalse(press(0x28, "k", command | option).isCommandChord("k"))
        XCTAssertFalse(press(0x28, "k", ignoring: "k", command | control).isCommandChord("k"))
    }

    func testCommandChordNeedsCommand() {
        XCTAssertFalse(press(0x28, "k").isCommandChord("k"))
        XCTAssertFalse(press(0x28, "K", shift).isCommandChord("k"))
    }

    // MARK: ⌘1–9

    func testCommandDigitIsOneToNine() {
        XCTAssertEqual(press(0x12, "1", command).commandDigit, 1)
        XCTAssertEqual(press(0x19, "9", command).commandDigit, 9)
        XCTAssertEqual(press(0x12, "1", command | shift).commandDigit, 1)
    }

    func testCommandDigitRefusesZeroLettersAndOtherModifiers() {
        XCTAssertNil(press(0x1D, "0", command).commandDigit)
        XCTAssertNil(press(0x28, "k", command).commandDigit)
        XCTAssertNil(press(0x12, "1").commandDigit)
        XCTAssertNil(press(0x12, "1", command | option).commandDigit)
        XCTAssertNil(press(0x12, "1", command | control).commandDigit)
    }

    /// A layout whose digit row needs shift types `&` on ⌘1: no ordinal.
    func testCommandDigitIsTheProducedCharacter() {
        XCTAssertNil(press(0x12, "&", command).commandDigit)
    }

    // MARK: typed text

    func testTypedIsOnePrintableCharacter() {
        XCTAssertEqual(press(0x00, "a").typed, "a")
        XCTAssertEqual(press(0x00, "A", shift).typed, "A")
        XCTAssertEqual(press(0x31, " ").typed, " ")
        XCTAssertEqual(press(0x00, "é").typed, "é")
    }

    func testTypedRefusesChords() {
        XCTAssertNil(press(0x00, "a", command).typed)
        XCTAssertNil(press(0x00, "å", ignoring: "a", option).typed)
        XCTAssertNil(press(0x00, "\u{1}", ignoring: "a", control).typed)
    }

    func testTypedRefusesKeysThatProduceNoText() {
        XCTAssertNil(press(53, "\u{1b}").typed, "escape")
        XCTAssertNil(press(36, "\r").typed, "return")
        XCTAssertNil(press(51, "\u{7f}").typed, "delete")
        XCTAssertNil(press(126, "\u{F700}", function | numericPad).typed, "an arrow's private-use scalar")
        XCTAssertNil(press(0x00, "").typed, "a dead key")
        XCTAssertNil(press(0x00, "ab").typed, "more than one character")
        XCTAssertNil(press(0x00, "😀").typed, "more than one UTF-16 unit, as the web app counts")
    }
}
