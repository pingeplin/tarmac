import XCTest
@testable import TarmacKit

/// `tarmac dev key <card> "<combo>"` (spec 2609.0015, #166): a closed grammar, so
/// a typo fails loudly, planned as the key stroke AppKit would deliver for it on
/// a US layout. Expected key codes come from `HIToolboxVirtualKeyCodes`.
final class DevKeyComboTests: XCTestCase {
    private typealias Flags = DevKeyStroke.ModifierFlags
    private typealias VK = HIToolboxVirtualKeyCodes

    private func stroke(_ combo: String, file: StaticString = #filePath, line: UInt = #line) -> DevKeyStroke? {
        guard case .stroke(let stroke) = DevKeyCombo.parse(combo) else {
            XCTFail("\(combo) did not plan a stroke: \(DevKeyCombo.parse(combo))", file: file, line: line)
            return nil
        }
        return stroke
    }

    private func refusal(_ combo: String, file: StaticString = #filePath, line: UInt = #line) -> DevError? {
        guard case .refused(let error) = DevKeyCombo.parse(combo) else {
            XCTFail("\(combo) was not refused: \(DevKeyCombo.parse(combo))", file: file, line: line)
            return nil
        }
        return error
    }

    private func ansi(_ key: Character) -> UInt16 { VK.ansi[key]! }

    // MARK: - S9–S12 the named keys

    func testS9EnterIsReturnWithNoModifiers() {
        XCTAssertEqual(stroke("enter"), DevKeyStroke(
            keyCode: VK.returnKey, modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r"
        ))
    }

    func testS10ControlCCarriesTheControlCharacterAndThePlainLetter() {
        XCTAssertEqual(stroke("ctrl+c"), DevKeyStroke(
            keyCode: ansi("c"), modifierFlags: .control, characters: "\u{03}", charactersIgnoringModifiers: "c"
        ))
    }

    func testS11ShiftEnterSetsShiftOnTheSameKey() {
        XCTAssertEqual(stroke("shift+enter"), DevKeyStroke(
            keyCode: VK.returnKey, modifierFlags: .shift, characters: "\r", charactersIgnoringModifiers: "\r"
        ))
    }

    func testS12EscapeIsTheEscapeKey() {
        XCTAssertEqual(stroke("escape"), DevKeyStroke(
            keyCode: VK.escape, modifierFlags: [], characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}"
        ))
    }

    /// The app's key bindings match on the key code and an exact modifier set
    /// (#21), so the planned stroke is fed to the real rule rather than restated.
    func testS12bAltLeftIsTheStrokeTheWordMotionBindingMatches() throws {
        let planned = try XCTUnwrap(stroke("alt+left"))
        XCTAssertEqual(planned, DevKeyStroke(
            keyCode: VK.leftArrow, modifierFlags: [.option, .function, .numericPad],
            characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}"
        ))
        XCTAssertEqual(
            TermKeyBinding.bytes(keyCode: planned.keyCode, modifierFlags: planned.modifierFlags.rawValue, composing: false),
            [0x1b, 0x62]
        )
    }

    /// It cycles the prime terminal and so MOVES FOCUS, which breaks the
    /// `not_focused` precondition for a later verb; that is documented, not
    /// enforced by the grammar.
    func testS12cAltTabPlansLikeAnyOtherCombo() {
        XCTAssertEqual(stroke("alt+tab"), DevKeyStroke(
            keyCode: VK.tab, modifierFlags: .option, characters: "\t", charactersIgnoringModifiers: "\t"
        ))
    }

    // MARK: - S13 the whole accepted set

    private static let namedKeys = ["enter", "tab", "escape", "backspace", "up", "down", "left", "right"]
    private static let modifierSets: [(prefix: String, flags: DevKeyStroke.ModifierFlags)] = [
        ("", []), ("ctrl+", .control), ("shift+", .shift), ("alt+", .option),
        ("ctrl+shift+", [.control, .shift]), ("ctrl+alt+", [.control, .option]), ("alt+shift+", [.option, .shift]),
        ("shift+alt+ctrl+", [.control, .shift, .option]),
    ]
    private static let chordModifierSets = modifierSets.filter { $0.flags.contains(.control) || $0.flags.contains(.option) }
    private static let intent: DevKeyStroke.ModifierFlags = [.shift, .control, .option]

    func testS13EveryNamedKeyTakesEveryModifierSet() throws {
        for key in Self.namedKeys {
            for (prefix, flags) in Self.modifierSets {
                let planned = try XCTUnwrap(stroke(prefix + key))
                XCTAssertEqual(planned.modifierFlags.intersection(Self.intent), flags, prefix + key)
                XCTAssertEqual(planned.keyCode, stroke(key)?.keyCode, prefix + key)
                XCTAssertFalse(planned.characters.isEmpty, prefix + key)
                XCTAssertFalse(planned.charactersIgnoringModifiers.isEmpty, prefix + key)
            }
        }
    }

    func testS13ALetterOrDigitTakesEveryModifierSetThatHasControlOrOption() throws {
        for base in ["c", "7"] {
            for (prefix, flags) in Self.chordModifierSets {
                let planned = try XCTUnwrap(stroke(prefix + base))
                XCTAssertEqual(planned.modifierFlags, flags, prefix + base)
                XCTAssertEqual(planned.keyCode, ansi(Character(base)), prefix + base)
                XCTAssertFalse(planned.characters.isEmpty, prefix + base)
            }
        }
    }

    /// The values, not just the shape: without this `up` could carry the down
    /// arrow's key code and send the wrong key with the whole suite green.
    func testS13EachNamedKeyIsExactlyItsKeyCodeAndCharacter() {
        let arrow: Flags = [.function, .numericPad]
        let rows: [(String, UInt16, String, Flags)] = [
            ("enter", VK.returnKey, "\r", []),
            ("tab", VK.tab, "\t", []),
            ("escape", VK.escape, "\u{1B}", []),
            ("backspace", VK.delete, "\u{7F}", []),
            ("up", VK.upArrow, "\u{F700}", arrow),
            ("down", VK.downArrow, "\u{F701}", arrow),
            ("left", VK.leftArrow, "\u{F702}", arrow),
            ("right", VK.rightArrow, "\u{F703}", arrow),
        ]
        for (combo, keyCode, characters, flags) in rows {
            XCTAssertEqual(stroke(combo), DevKeyStroke(
                keyCode: keyCode, modifierFlags: flags, characters: characters, charactersIgnoringModifiers: characters
            ), combo)
        }
    }

    /// AppKit delivers Shift-Tab as the back-tab character in both fields.
    func testAShiftedTabIsTheBackTabCharacter() {
        for combo in ["shift+tab", "ctrl+shift+tab", "alt+shift+tab"] {
            XCTAssertEqual(stroke(combo)?.characters, "\u{19}", combo)
            XCTAssertEqual(stroke(combo)?.charactersIgnoringModifiers, "\u{19}", combo)
        }
        XCTAssertEqual(stroke("ctrl+tab")?.characters, "\t")
        XCTAssertEqual(stroke("shift+enter")?.characters, "\r")
    }

    /// `charactersIgnoringModifiers` keeps Shift: the capital, or the digit key's
    /// US symbol.
    func testS13ShiftChangesTheFaceIgnoringModifiers() {
        XCTAssertEqual(stroke("ctrl+shift+c")?.charactersIgnoringModifiers, "C")
        XCTAssertEqual(stroke("ctrl+c")?.charactersIgnoringModifiers, "c")
        XCTAssertEqual(stroke("ctrl+shift+7")?.charactersIgnoringModifiers, "&")
        XCTAssertEqual(stroke("ctrl+7")?.charactersIgnoringModifiers, "7")
        XCTAssertEqual(stroke("alt+shift+0")?.charactersIgnoringModifiers, ")")
    }

    func testControlTurnsEveryLetterIntoItsControlCharacter() {
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            let expected = String(UnicodeScalar(UInt8(offset + 1)))
            for prefix in ["ctrl+", "ctrl+shift+", "ctrl+alt+", "ctrl+alt+shift+"] {
                XCTAssertEqual(stroke(prefix + String(letter))?.characters, expected, prefix + String(letter))
            }
        }
    }

    /// Measured off `NSEvent(cgEvent:)`: Control leaves a digit alone, except that
    /// with Shift the `@` and `^` faces become their control characters.
    func testControlLeavesADigitAloneExceptTheTwoShiftedFacesWithAControlCharacter() {
        for digit in "0123456789" {
            XCTAssertEqual(stroke("ctrl+\(digit)")?.characters, String(digit))
            XCTAssertEqual(stroke("ctrl+alt+\(digit)")?.characters, String(digit))
        }
        for digit in "01345789" {
            XCTAssertEqual(stroke("ctrl+shift+\(digit)")?.characters, String(digit))
        }
        for prefix in ["ctrl+shift+", "ctrl+alt+shift+"] {
            XCTAssertEqual(stroke(prefix + "2")?.characters, "\u{00}")
            XCTAssertEqual(stroke(prefix + "6")?.characters, "\u{1E}")
        }
    }

    /// The Option layer's own glyph (`ç`) is not carried: a terminal that treats
    /// Option as Alt re-derives the text without it, from the key code.
    func testOptionAloneCarriesTheFaceWithoutTheOptionLayer() {
        XCTAssertEqual(stroke("alt+c")?.characters, "c")
        XCTAssertEqual(stroke("alt+shift+c")?.characters, "C")
        XCTAssertEqual(stroke("alt+7")?.characters, "7")
        XCTAssertEqual(stroke("alt+shift+7")?.characters, "&")
    }

    func testEveryLetterAndDigitMapsToItsOwnKey() {
        for base in "abcdefghijklmnopqrstuvwxyz0123456789" {
            XCTAssertEqual(stroke("ctrl+\(base)")?.keyCode, ansi(base), String(base))
            XCTAssertEqual(stroke("ctrl+\(base)")?.charactersIgnoringModifiers, String(base))
        }
    }

    // MARK: - S14 refusals with a reason

    func testS14bABarePrintableIsRefusedWithTypeAsTheRemedy() {
        for combo in ["a", "7", "shift+a", "shift+7"] {
            let error = refusal(combo)
            XCTAssertEqual(error?.code, .unsupportedCombo, combo)
            XCTAssertEqual(error?.message.contains("tarmac dev type"), true, combo)
        }
    }

    func testS14CommandChordsAreRefusedAndPointAtPress() {
        for combo in ["cmd+c", "meta+v", "cmd+q", "meta+q", "ctrl+cmd+c"] {
            let error = refusal(combo)
            XCTAssertEqual(error?.code, .unsupportedCombo, combo)
            XCTAssertEqual(error?.message.contains("menu"), true, combo)
            XCTAssertEqual(error?.message.contains("tarmac dev press cmd+"), true, combo)
        }
    }

    /// The ⌘ check comes first, so the answer names the reason rather than the
    /// nearest spelling mistake.
    func testACommandChordIsUnsupportedWhateverElseIsWrongWithIt() {
        for combo in ["cmd+frobnicate", "cmd+hyper+c", "cmd+ctrl+ctrl+c", "cmd+contextmenu", "cmd+"] {
            XCTAssertEqual(refusal(combo)?.code, .unsupportedCombo, combo)
        }
    }

    // MARK: - S15 malformed combos

    /// `CTRL+C` pins that the grammar is lowercase-only rather than case-folded.
    func testS15MalformedCombosAreBadComboNeverANeighbour() {
        for combo in ["ctrl+", "", "frobnicate", "CTRL+C", "ctrl+shift", "+", "ctrl++c", "ctrl+C", "ctrl+ab", "ctrl+é"] {
            XCTAssertEqual(refusal(combo)?.code, .badCombo, combo)
        }
    }

    /// Each part on its own: a modifier, a named key or `contextmenu` in another
    /// case must not fold onto the lowercase one.
    func testNoPartOfAComboIsCaseFolded() {
        for combo in ["CTRL+c", "Ctrl+c", "SHIFT+enter", "Alt+left", "ENTER", "Enter", "ctrl+Enter", "ContextMenu"] {
            XCTAssertEqual(refusal(combo)?.code, .badCombo, combo)
        }
        XCTAssertEqual(refusal("CMD+c")?.code, .badCombo)
    }

    func testAnUnknownOrRepeatedModifierIsBadCombo() {
        XCTAssertEqual(refusal("hyper+c")?.code, .badCombo)
        XCTAssertEqual(refusal("ctrl+ctrl+c")?.code, .badCombo)
        XCTAssertEqual(refusal("shift+shift+enter")?.code, .badCombo)
        XCTAssertEqual(refusal("enter+ctrl")?.code, .badCombo)
    }

    func testARefusalNamesTheComboItRefused() {
        XCTAssertEqual(refusal("frobnicate")?.extra, ["combo": "frobnicate"])
        XCTAssertEqual(refusal("cmd+c")?.extra, ["combo": "cmd+c"])
        XCTAssertEqual(refusal("a")?.extra, ["combo": "a"])
        XCTAssertEqual(refusal("ctrl+contextmenu")?.extra, ["combo": "ctrl+contextmenu"])
    }

    // MARK: - S16 contextmenu

    func testS16ContextMenuIsItsOwnOutcomeAndTakesNoModifiers() {
        XCTAssertEqual(DevKeyCombo.parse("contextmenu"), .contextMenu)
        XCTAssertEqual(DevKeyCombo.contextMenu, "contextmenu")
        XCTAssertEqual(refusal("ctrl+contextmenu")?.code, .badCombo)
        XCTAssertEqual(refusal("shift+contextmenu")?.code, .badCombo)
    }

    // MARK: - the reply

    /// `smoke.mjs` D7 compares `events` against `["keydown","keyup"]` verbatim.
    func testTheReplyNamesTheComboAndTheEventsDelivered() {
        XCTAssertEqual(DevKeyCombo.strokeEvents, ["keydown", "keyup"])
        XCTAssertEqual(DevKeyCombo.contextMenuEvents, ["contextmenu"])
        XCTAssertEqual(
            DevKeyCombo.reply(combo: "ctrl+c", events: DevKeyCombo.strokeEvents).jsonString,
            #"{"combo":"ctrl+c","events":["keydown","keyup"]}"#
        )
    }

    // MARK: - the US-layout physical key behind an ASCII printable

    func testAPrintableResolvesToItsUnshiftedKeyAndWhetherItNeedsShift() {
        let rows: [(Character, UInt16, Bool)] = [
            ("a", ansi("a"), false), ("z", ansi("z"), false), ("A", ansi("a"), true), ("Z", ansi("z"), true),
            ("0", ansi("0"), false), ("1", ansi("1"), false), ("9", ansi("9"), false),
            (")", ansi("0"), true), ("!", ansi("1"), true), ("@", ansi("2"), true), ("#", ansi("3"), true),
            ("$", ansi("4"), true), ("%", ansi("5"), true), ("^", ansi("6"), true), ("&", ansi("7"), true),
            ("*", ansi("8"), true), ("(", ansi("9"), true),
            (" ", VK.space, false),
            (";", ansi(";"), false), (":", ansi(";"), true), ("=", ansi("="), false), ("+", ansi("="), true),
            (",", ansi(","), false), ("<", ansi(","), true), ("-", ansi("-"), false), ("_", ansi("-"), true),
            (".", ansi("."), false), (">", ansi("."), true), ("/", ansi("/"), false), ("?", ansi("/"), true),
            ("`", ansi("`"), false), ("~", ansi("`"), true), ("[", ansi("["), false), ("{", ansi("["), true),
            ("\\", ansi("\\"), false), ("|", ansi("\\"), true), ("]", ansi("]"), false), ("}", ansi("]"), true),
            ("'", ansi("'"), false), ("\"", ansi("'"), true),
        ]
        for (char, keyCode, shift) in rows {
            XCTAssertEqual(
                DevKeyCombo.physicalKey(for: char.unicodeScalars.first!),
                DevKeyCombo.PhysicalKey(keyCode: keyCode, shift: shift),
                String(char)
            )
        }
    }

    func testEveryASCIIPrintableHasAKeyAndNothingElseDoes() {
        for value in UInt8(0x20)...0x7E {
            XCTAssertNotNil(DevKeyCombo.physicalKey(for: UnicodeScalar(value)), "U+00\(String(value, radix: 16))")
        }
        for scalar in ["\u{00}", "\u{1B}", "\u{1F}", "\u{7F}", "\u{A0}", "é", "中", "😀"] as [Unicode.Scalar] {
            XCTAssertNil(DevKeyCombo.physicalKey(for: scalar), "U+\(String(scalar.value, radix: 16))")
        }
    }
}
