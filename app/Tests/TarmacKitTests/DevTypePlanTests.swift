import XCTest
@testable import TarmacKit

/// `tarmac dev type <card> "<text>"` (spec 2609.0015, #166): which path each
/// code point takes into the terminal, and the reply built from what the driver
/// then observed.
final class DevTypePlanTests: XCTestCase {
    private typealias Step = DevTypePlan.Step
    private typealias VK = HIToolboxVirtualKeyCodes

    private func steps(_ text: String, flags: UInt8 = 0) -> [Step] {
        DevTypePlan.plan(text: text, kittyFlags: flags).steps
    }

    private func comboStroke(_ combo: String, file: StaticString = #filePath, line: UInt = #line) -> DevKeyStroke {
        guard case .stroke(let stroke) = DevKeyCombo.parse(combo) else {
            XCTFail("\(combo) is not a stroke", file: file, line: line)
            return DevKeyStroke(keyCode: .max, modifierFlags: [], characters: "", charactersIgnoringModifiers: "")
        }
        return stroke
    }

    // MARK: - S19 printables are inserted, one code point at a time

    func testS19APrintableIsOneInsertPerCharacter() {
        let plan = DevTypePlan.plan(text: "ab", kittyFlags: 0)
        XCTAssertEqual(plan.mode, .insert)
        XCTAssertEqual(plan.steps, [.insert(index: 0, char: "a"), .insert(index: 1, char: "b")])
    }

    // MARK: - S77 kitty flag 8 switches the whole delivery path

    func testS77TheInsertPathHoldsUnderFlagsThatDoNotReportAllKeys() {
        for flags: UInt8 in [0, 1, 2, 4, 5, 16, 23] {
            let plan = DevTypePlan.plan(text: "a", kittyFlags: flags)
            XCTAssertEqual(plan.mode, .insert, "flags \(flags)")
            XCTAssertEqual(plan.steps, [.insert(index: 0, char: "a")], "flags \(flags)")
        }
    }

    /// Under flag 8 the program is sent every key as an escape code, which only a
    /// key press produces; inserted text would arrive as text it did not ask for.
    func testS77FlagEightPlansAKeyStrokeAndNoInsert() {
        let plan = DevTypePlan.plan(text: "a", kittyFlags: 8)
        XCTAssertEqual(plan.mode, .key)
        XCTAssertEqual(plan.steps, [.key(index: 0, char: "a", stroke: DevKeyStroke(
            keyCode: VK.ansi["a"]!, modifierFlags: [], characters: "a", charactersIgnoringModifiers: "a"
        ))])
    }

    func testS77FlagEightSwitchesWhereverItSitsInTheMask() {
        XCTAssertEqual(DevTypePlan.plan(text: "a", kittyFlags: 13).mode, .key)
        XCTAssertEqual(DevTypePlan.plan(text: "a", kittyFlags: 31).mode, .key)
        XCTAssertEqual(DevTypePlan.reportAllKeysAsEscapeCodes, 8)
    }

    /// kitty encodes the UNSHIFTED key plus a shift modifier, so `!` must be the
    /// `1` key with Shift, not a key of its own.
    func testS77AShiftedPrintableIsItsUnshiftedKeyWithShift() {
        XCTAssertEqual(steps("!A ", flags: 8), [
            .key(index: 0, char: "!", stroke: DevKeyStroke(
                keyCode: VK.ansi["1"]!, modifierFlags: .shift, characters: "!", charactersIgnoringModifiers: "!"
            )),
            .key(index: 1, char: "A", stroke: DevKeyStroke(
                keyCode: VK.ansi["a"]!, modifierFlags: .shift, characters: "A", charactersIgnoringModifiers: "A"
            )),
            .key(index: 2, char: " ", stroke: DevKeyStroke(
                keyCode: VK.space, modifierFlags: [], characters: " ", charactersIgnoringModifiers: " "
            )),
        ])
    }

    func testS77EveryASCIIPrintableIsAKeyStrokeUnderFlagEight() {
        for value in UInt8(0x20)...0x7E {
            let char = String(UnicodeScalar(value))
            guard case .key(0, char, let stroke)? = steps(char, flags: 8).first else {
                XCTFail("\(char) is not a key step")
                continue
            }
            XCTAssertEqual(stroke.characters, char)
            XCTAssertEqual(DevKeyCombo.PhysicalKey(keyCode: stroke.keyCode, shift: stroke.modifierFlags == .shift),
                           DevKeyCombo.physicalKey(for: UnicodeScalar(value)))
        }
    }

    /// No layout to read a key from, so nothing is pressed and the reply says so.
    func testS77ACharacterWithNoKeyIsDroppedUnderFlagEight() {
        XCTAssertEqual(steps("a中\u{00}\u{1C}é", flags: 8), [
            .key(index: 0, char: "a", stroke: comboStrokeForPrintable("a")),
            .drop(index: 1, char: "中"),
            .drop(index: 2, char: "\u{00}"),
            .drop(index: 3, char: "\u{1C}"),
            .drop(index: 4, char: "é"),
        ])
    }

    private func comboStrokeForPrintable(_ char: Unicode.Scalar) -> DevKeyStroke {
        DevKeyStroke(
            keyCode: VK.ansi[Character(char)]!, modifierFlags: [], characters: String(char),
            charactersIgnoringModifiers: String(char)
        )
    }

    // MARK: - S20/S21/S22 control characters are key strokes in both modes

    func testS20ANewlineOrCarriageReturnIsTheEnterStroke() {
        for flags: UInt8 in [0, 8] {
            XCTAssertEqual(steps("\n", flags: flags), [.key(index: 0, char: "\n", stroke: comboStroke("enter"))])
            XCTAssertEqual(steps("\r", flags: flags), [.key(index: 0, char: "\r", stroke: comboStroke("enter"))])
        }
    }

    func testS21TheOtherNamedControlsAreTheirKeys() {
        for flags: UInt8 in [0, 8] {
            XCTAssertEqual(steps("\t", flags: flags), [.key(index: 0, char: "\t", stroke: comboStroke("tab"))])
            XCTAssertEqual(steps("\u{1B}", flags: flags), [.key(index: 0, char: "\u{1B}", stroke: comboStroke("escape"))])
            XCTAssertEqual(steps("\u{7F}", flags: flags), [.key(index: 0, char: "\u{7F}", stroke: comboStroke("backspace"))])
        }
    }

    /// A rule rather than a list, so `\x03` is not a special case and no letter
    /// chord is missing.
    func testS22TheRestOfC0IsTheControlChordItStandsFor() {
        XCTAssertEqual(steps("\u{03}"), [.key(index: 0, char: "\u{03}", stroke: comboStroke("ctrl+c"))])
        XCTAssertEqual(steps("\u{04}", flags: 8), [.key(index: 0, char: "\u{04}", stroke: comboStroke("ctrl+d"))])
        let named: Set<UInt8> = [0x09, 0x0A, 0x0D]
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() where !named.contains(UInt8(offset + 1)) {
            let char = String(UnicodeScalar(UInt8(offset + 1)))
            XCTAssertEqual(steps(char), [.key(index: 0, char: char, stroke: comboStroke("ctrl+\(letter)"))], "ctrl+\(letter)")
        }
    }

    /// `\x00` and `\x1c`–`\x1f` have no spelling in the combo grammar, so they
    /// take the insert path like any other character.
    func testAControlCharacterWithNoChordIsInserted() {
        for value: UInt8 in [0x00, 0x1C, 0x1D, 0x1E, 0x1F] {
            let char = String(UnicodeScalar(value))
            XCTAssertEqual(steps(char), [.insert(index: 0, char: char)], "U+00\(String(value, radix: 16))")
        }
    }

    // MARK: - S23 order, and what one step is

    func testS23AMixedStringKeepsItsOrder() {
        XCTAssertEqual(steps("a\nb"), [
            .insert(index: 0, char: "a"),
            .key(index: 1, char: "\n", stroke: comboStroke("enter")),
            .insert(index: 2, char: "b"),
        ])
    }

    /// By code point, as the Tauri driver counts: `\r\n` is two Returns, and a
    /// combining mark is its own step. A grapheme walk would merge both.
    func testAStepIsOneCodePointNotOneGrapheme() {
        XCTAssertEqual(steps("\r\n"), [
            .key(index: 0, char: "\r", stroke: comboStroke("enter")),
            .key(index: 1, char: "\n", stroke: comboStroke("enter")),
        ])
        XCTAssertEqual(steps("e\u{301}"), [.insert(index: 0, char: "e"), .insert(index: 1, char: "\u{301}")])
        XCTAssertEqual(steps("a😀b"), [
            .insert(index: 0, char: "a"), .insert(index: 1, char: "😀"), .insert(index: 2, char: "b"),
        ])
    }

    // MARK: - S24 a non-ASCII printable

    func testS24ANonASCIIPrintableIsInserted() {
        XCTAssertEqual(steps("中"), [.insert(index: 0, char: "中")])
    }

    // MARK: - S71 the reply is built from what the driver observed

    func testS71AKeyStepCountsInCharsButIsNeitherInsertedNorDropped() {
        let plan = DevTypePlan.plan(text: "a\nb", kittyFlags: 0)
        XCTAssertEqual(
            DevTypePlan.summary(of: plan, inserted: [true, true]),
            ["chars": 3, "inserted": 2, "dropped": [], "mode": "insert"]
        )
    }

    /// `smoke.mjs`'s `typeAll` fails a scenario on a non-empty `dropped`; a
    /// summary that could not report one would make that check unfalsifiable.
    func testS71ADroppedCharacterIsReportedByItsIndexInTheRequestedString() {
        let plan = DevTypePlan.plan(text: "a\nb", kittyFlags: 0)
        XCTAssertEqual(
            DevTypePlan.summary(of: plan, inserted: [true, false]),
            ["chars": 3, "inserted": 1, "dropped": [["index": 2, "char": "b"]], "mode": "insert"]
        )
        XCTAssertEqual(
            DevTypePlan.summary(of: plan, inserted: [false, true]),
            ["chars": 3, "inserted": 1, "dropped": [["index": 0, "char": "a"]], "mode": "insert"]
        )
    }

    func testS71AnInsertWithNoObservationCountsAsDropped() {
        let plan = DevTypePlan.plan(text: "ab", kittyFlags: 0)
        XCTAssertEqual(
            DevTypePlan.summary(of: plan, inserted: [true]),
            ["chars": 2, "inserted": 1, "dropped": [["index": 1, "char": "b"]], "mode": "insert"]
        )
    }

    func testS71NothingIsInsertedUnderFlagEight() {
        XCTAssertEqual(
            DevTypePlan.summary(of: DevTypePlan.plan(text: "a\nb", kittyFlags: 8), inserted: []),
            ["chars": 3, "inserted": 0, "dropped": [], "mode": "key"]
        )
    }

    func testACharacterWithNoKeyIsReportedDroppedUnderFlagEight() {
        XCTAssertEqual(
            DevTypePlan.summary(of: DevTypePlan.plan(text: "a中b", kittyFlags: 8), inserted: []),
            ["chars": 3, "inserted": 0, "dropped": [["index": 1, "char": "中"]], "mode": "key"]
        )
    }

    func testEmptyTextPlansNothingAndSummarisesToZeroes() {
        let plan = DevTypePlan.plan(text: "", kittyFlags: 0)
        XCTAssertEqual(plan.steps, [])
        XCTAssertEqual(
            DevTypePlan.summary(of: plan, inserted: []),
            ["chars": 0, "inserted": 0, "dropped": [], "mode": "insert"]
        )
    }

    func testTheReplyBodyIsTheSummaryAsJSON() {
        let plan = DevTypePlan.plan(text: "a\nb", kittyFlags: 0)
        XCTAssertEqual(
            DevTypePlan.summary(of: plan, inserted: [true, false]).jsonString,
            #"{"chars":3,"dropped":[{"char":"b","index":2}],"inserted":1,"mode":"insert"}"#
        )
    }
}
