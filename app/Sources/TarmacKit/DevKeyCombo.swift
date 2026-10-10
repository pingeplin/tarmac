import Foundation

/// One key press as AppKit describes it — the four facts `NSEvent.keyEvent(with:…)`
/// needs beyond where and when. The app posts it as a key-down then a key-up.
/// A press with Control is not built by `NSEvent.keyEvent`, and of the two
/// character fields it delivers `characters` only (`isKeyEquivalentCandidate`).
///
/// `keyCode` is the load-bearing field: the app's key bindings and the terminal's
/// encoder both read the physical key. It and the modifier flags are exactly a
/// real press's on a US layout, and so are the character fields — except for a
/// chord with Option and no Control, where `characters` is the face without the
/// Option layer: a real ⌥B carries `∫`, this carries `b`. The terminal view
/// re-derives that text from the key code while it treats Option as Alt; a
/// handler that reads `characters` of an Option chord sees the difference.
public struct DevKeyStroke: Equatable, Sendable {
    /// `NSEvent.ModifierFlags` raw bits, restated so the kit stays AppKit-free.
    public struct ModifierFlags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt

        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }

        public static let shift = ModifierFlags(rawValue: 1 << 17)
        public static let control = ModifierFlags(rawValue: 1 << 18)
        public static let option = ModifierFlags(rawValue: 1 << 19)
        public static let numericPad = ModifierFlags(rawValue: 1 << 21)
        public static let function = ModifierFlags(rawValue: 1 << 23)
    }

    public var keyCode: UInt16
    public var modifierFlags: ModifierFlags
    public var characters: String
    public var charactersIgnoringModifiers: String

    public init(keyCode: UInt16, modifierFlags: ModifierFlags, characters: String, charactersIgnoringModifiers: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
    }

    /// AppKit offers a press with Control to key equivalents — the menu —
    /// before `keyDown` (⌘ too, which `key` refuses). The driver builds such a
    /// press another way (`DevInput.press`, #207).
    public var isKeyEquivalentCandidate: Bool { modifierFlags.contains(.control) }
}

/// What `tarmac dev key <card> "<combo>"` presses (spec 2609.0015, issue #166).
///
/// The grammar is a CLOSED set on purpose: a scenario that typos a combo must
/// fail loudly rather than silently send a neighbouring one. It is the Tauri
/// driver's grammar unchanged, so one scenario suite drives both apps — which is
/// why two shapes a native key event could deliver are still refused:
///   - `cmd`/`meta`: a ⌘ chord is a menu key equivalent. `tarmac dev press` posts
///     one through the application's event queue, behind the ⌘Q guard's checks.
///   - a bare letter or digit: a printable is text, and `tarmac dev type` is the
///     verb that exercises the text-input path. It is fine as the base of a
///     ctrl/alt chord, which is what `type` uses for `\x03` and friends.
///
/// A stroke describes a US layout, the only one a synthesized press can claim:
/// nobody pressed a key, so there is no layout to read.
public enum DevKeyCombo {
    public enum Outcome: Equatable, Sendable {
        case stroke(DevKeyStroke)
        /// Not a key: the driver right-clicks a cell (`DevCellPoint`).
        case contextMenu
        /// `bad_combo` or `unsupported_combo`, with the combo as `extra`.
        case refused(DevError)
    }

    /// The US-layout key that types an ASCII printable: its virtual key code, and
    /// whether Shift is held to reach that face.
    public struct PhysicalKey: Equatable, Sendable {
        public var keyCode: UInt16
        public var shift: Bool

        public init(keyCode: UInt16, shift: Bool) {
            self.keyCode = keyCode
            self.shift = shift
        }
    }

    /// Shared with routing, which must spell the verb the way the grammar does.
    public static let contextMenu = "contextmenu"

    /// The reply's `events` for a stroke. The names are the Tauri driver's, which
    /// the scenario suite compares verbatim; natively they are a key-down and a
    /// key-up.
    public static let strokeEvents = ["keydown", "keyup"]
    public static let contextMenuEvents = ["contextmenu"]

    /// Two answers differ from the Tauri driver's:
    ///   - a base named like an `Object.prototype` member (`toString`,
    ///     `constructor`) is `bad_combo` here; its table is an object literal, so
    ///     the lookup finds the inherited member and plans a key.
    ///   - a combo with both a repeated and an unknown modifier
    ///     (`ctrl+ctrl+foo+c`) is refused for whichever comes first; it reports the
    ///     unknown one. The code is `bad_combo` either way.
    public static func parse(_ combo: String) -> Outcome {
        let parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let base = parts[parts.count - 1]
        let names = parts.dropLast()

        func refused(_ code: DevError.Code, _ message: String) -> Outcome {
            .refused(DevError(code, message, extra: ["combo": .string(combo)]))
        }

        if names.contains(where: nativeModifiers.contains) {
            return refused(
                .unsupportedCombo,
                "⌘ chords are menu key equivalents, which `key` does not deliver; `tarmac dev press cmd+<letter or digit>` posts one natively"
            )
        }
        var flags: DevKeyStroke.ModifierFlags = []
        for name in names {
            guard let flag = modifiers[name] else {
                return refused(.badCombo, "unknown modifier in `\(combo)`; the set is ctrl, shift, alt (lowercase)")
            }
            guard flags.insert(flag).inserted else {
                return refused(.badCombo, "repeated modifier in `\(combo)`")
            }
        }

        if base == contextMenu {
            return flags.isEmpty ? .contextMenu : refused(.badCombo, "`contextmenu` takes no modifiers")
        }
        if let key = namedKeys.first(where: { $0.name == base }) {
            return .stroke(key.stroke(flags))
        }
        if let key = chordKey(base) {
            guard flags.contains(.control) || flags.contains(.option) else {
                return refused(
                    .unsupportedCombo,
                    "`\(combo)` is a printable character, which a terminal takes as text; use `tarmac dev type` instead"
                )
            }
            return .stroke(chord(key, flags))
        }
        return refused(
            .badCombo,
            "`\(combo)` is not in the combo grammar: a named key (\(namedKeys.map(\.name).joined(separator: ", "))), "
                + "a lowercase letter or digit with ctrl or alt, or `contextmenu`"
        )
    }

    public static func reply(combo: String, events: [String]) -> JSONValue {
        ["combo": .string(combo), "events": .array(events.map(JSONValue.string))]
    }

    public static func physicalKey(for scalar: Unicode.Scalar) -> PhysicalKey? {
        for key in usKeys {
            if key.plain == scalar { return PhysicalKey(keyCode: key.keyCode, shift: false) }
            if key.shifted == scalar { return PhysicalKey(keyCode: key.keyCode, shift: true) }
        }
        return nil
    }

    /// The stroke a real press of an ASCII printable makes — its key, with Shift
    /// where the face needs it. Nil for anything a US keyboard has no key for.
    static func printableStroke(_ scalar: Unicode.Scalar) -> DevKeyStroke? {
        guard let key = physicalKey(for: scalar) else { return nil }
        return DevKeyStroke(
            keyCode: key.keyCode,
            modifierFlags: key.shift ? .shift : [],
            characters: String(scalar),
            charactersIgnoringModifiers: String(scalar)
        )
    }

    // MARK: - tables

    private static let modifiers: [String: DevKeyStroke.ModifierFlags] = [
        "ctrl": .control, "shift": .shift, "alt": .option,
    ]
    private static let nativeModifiers: Set<String> = ["cmd", "meta"]

    private struct NamedKey {
        var name: String
        var keyCode: UInt16
        var characters: String
        var shiftedCharacters: String?
        var flags: DevKeyStroke.ModifierFlags = []

        func stroke(_ modifiers: DevKeyStroke.ModifierFlags) -> DevKeyStroke {
            let characters = modifiers.contains(.shift) ? shiftedCharacters ?? characters : characters
            return DevKeyStroke(
                keyCode: keyCode,
                modifierFlags: modifiers.union(flags),
                characters: characters,
                charactersIgnoringModifiers: characters
            )
        }
    }

    /// Key codes are Carbon's `kVK_*`; characters are what AppKit puts in the
    /// event — the arrows as its private-use function keys, with the two flags
    /// every arrow press carries, and Shift-Tab as the back-tab character.
    private static let namedKeys: [NamedKey] = [
        NamedKey(name: "enter", keyCode: 0x24, characters: "\r"),
        NamedKey(name: "tab", keyCode: 0x30, characters: "\t", shiftedCharacters: "\u{19}"),
        NamedKey(name: "escape", keyCode: 0x35, characters: "\u{1B}"),
        NamedKey(name: "backspace", keyCode: 0x33, characters: "\u{7F}"),
        NamedKey(name: "up", keyCode: 0x7E, characters: "\u{F700}", flags: [.function, .numericPad]),
        NamedKey(name: "down", keyCode: 0x7D, characters: "\u{F701}", flags: [.function, .numericPad]),
        NamedKey(name: "left", keyCode: 0x7B, characters: "\u{F702}", flags: [.function, .numericPad]),
        NamedKey(name: "right", keyCode: 0x7C, characters: "\u{F703}", flags: [.function, .numericPad]),
    ]

    private struct USKey {
        var keyCode: UInt16
        var plain: Unicode.Scalar
        var shifted: Unicode.Scalar

        init(_ keyCode: UInt16, _ plain: Unicode.Scalar, _ shifted: Unicode.Scalar) {
            self.keyCode = keyCode
            self.plain = plain
            self.shifted = shifted
        }
    }

    /// The ANSI keyboard under the US layout: `kVK_ANSI_*`, the face each key
    /// types, and the face it types with Shift.
    private static let usKeys: [USKey] = [
        USKey(0x00, "a", "A"), USKey(0x0B, "b", "B"), USKey(0x08, "c", "C"), USKey(0x02, "d", "D"),
        USKey(0x0E, "e", "E"), USKey(0x03, "f", "F"), USKey(0x05, "g", "G"), USKey(0x04, "h", "H"),
        USKey(0x22, "i", "I"), USKey(0x26, "j", "J"), USKey(0x28, "k", "K"), USKey(0x25, "l", "L"),
        USKey(0x2E, "m", "M"), USKey(0x2D, "n", "N"), USKey(0x1F, "o", "O"), USKey(0x23, "p", "P"),
        USKey(0x0C, "q", "Q"), USKey(0x0F, "r", "R"), USKey(0x01, "s", "S"), USKey(0x11, "t", "T"),
        USKey(0x20, "u", "U"), USKey(0x09, "v", "V"), USKey(0x0D, "w", "W"), USKey(0x07, "x", "X"),
        USKey(0x10, "y", "Y"), USKey(0x06, "z", "Z"),
        USKey(0x1D, "0", ")"), USKey(0x12, "1", "!"), USKey(0x13, "2", "@"), USKey(0x14, "3", "#"),
        USKey(0x15, "4", "$"), USKey(0x17, "5", "%"), USKey(0x16, "6", "^"), USKey(0x1A, "7", "&"),
        USKey(0x1C, "8", "*"), USKey(0x19, "9", "("),
        USKey(0x31, " ", " "),
        USKey(0x29, ";", ":"), USKey(0x18, "=", "+"), USKey(0x2B, ",", "<"), USKey(0x1B, "-", "_"),
        USKey(0x2F, ".", ">"), USKey(0x2C, "/", "?"), USKey(0x32, "`", "~"), USKey(0x21, "[", "{"),
        USKey(0x2A, "\\", "|"), USKey(0x1E, "]", "}"), USKey(0x27, "'", "\""),
    ]

    /// The key behind a chord's base: one lowercase ASCII letter or digit.
    private static func chordKey(_ base: String) -> USKey? {
        guard base.unicodeScalars.count == 1, let scalar = base.unicodeScalars.first,
              ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
        else { return nil }
        return usKeys.first { $0.plain == scalar }
    }

    /// Measured off `NSEvent(cgEvent:)`: under Control a digit key still types its
    /// digit, except these two, whose shifted faces `@` and `^` have a control
    /// character of their own.
    private static let controlShiftedDigits: [Unicode.Scalar: String] = ["2": "\u{00}", "6": "\u{1E}"]

    private static func chord(_ key: USKey, _ flags: DevKeyStroke.ModifierFlags) -> DevKeyStroke {
        let shift = flags.contains(.shift)
        let face = String(shift ? key.shifted : key.plain)
        let characters: String
        if !flags.contains(.control) {
            // AppKit would deliver the Option layer's glyph (`ç`). A terminal that
            // treats Option as Alt discards it and re-derives the text from the key
            // code, so the face is carried instead of a 72-entry glyph table.
            characters = face
        } else if ("a"..."z").contains(key.plain) {
            characters = String(Unicode.Scalar(UInt8(key.plain.value & 0x1F)))
        } else {
            characters = shift ? controlShiftedDigits[key.plain] ?? String(key.plain) : String(key.plain)
        }
        return DevKeyStroke(
            keyCode: key.keyCode,
            modifierFlags: flags,
            characters: characters,
            charactersIgnoringModifiers: face
        )
    }
}
