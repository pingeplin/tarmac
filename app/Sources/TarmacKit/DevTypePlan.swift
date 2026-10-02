import Foundation

/// How `tarmac dev type <card> "<text>"` delivers each code point (spec
/// 2609.0015, issue #166).
///
/// Two paths, and which one a character takes is the decision:
///
///  - A PRINTABLE is inserted through the text-input path (`insertText`), the one
///    a committed keystroke or an input method ends in. That is the path #162
///    broke, so it is the path the scenarios must exercise.
///
///  - A CONTROL CHARACTER is a key stroke, because it is a key and not text:
///    `\n`, `\r`, `\t`, `\x1b` and `\x7f` are the named keys, and `\x01`–`\x1a`
///    are the ctrl chords they stand for (`\x03` → ctrl+c) — a rule rather than a
///    list. `\x00` and `\x1c`–`\x1f` have no spelling in the combo grammar, so
///    they take the insert path like any other character.
///
/// Under KITTY FLAG 8 a program is sent every key as an escape code, which only a
/// key press produces, so printables become strokes too — the US-layout key
/// behind each, with Shift where the face needs it. A character no US key types
/// cannot be pressed; it is dropped and the reply says so. Consequence for
/// scenarios: under flag 8 `type` does not exercise the insert path at all.
public enum DevTypePlan {
    /// How PRINTABLE characters are delivered. Control characters are key strokes
    /// in both modes.
    public enum Mode: String, Equatable, Sendable {
        case insert, key
    }

    /// `index` counts code points in the requested text; `char` is that one.
    public enum Step: Equatable, Sendable {
        case insert(index: Int, char: String)
        case key(index: Int, char: String, stroke: DevKeyStroke)
        case drop(index: Int, char: String)
    }

    public struct Plan: Equatable, Sendable {
        public var mode: Mode
        public var steps: [Step]

        public init(mode: Mode, steps: [Step]) {
            self.mode = mode
            self.steps = steps
        }

        /// Whether any step is a key stroke. A stroke is delivered to the key
        /// window; an insertion goes straight to the terminal and needs none.
        public var pressesKeys: Bool {
            steps.contains { step in
                if case .key = step { return true }
                return false
            }
        }
    }

    /// The one kitty keyboard flag under which a program receives plain
    /// printables as key events.
    public static let reportAllKeysAsEscapeCodes: UInt8 = 8

    public static func plan(text: String, kittyFlags: UInt8) -> Plan {
        let mode: Mode = kittyFlags & reportAllKeysAsEscapeCodes != 0 ? .key : .insert
        // By code point, so `index` counts as the caller's string does; a grapheme
        // walk would fold `\r\n` into one step.
        let steps = text.unicodeScalars.enumerated().map { index, scalar -> Step in
            let char = String(scalar)
            if let combo = controlCombo(scalar) {
                guard case .stroke(let stroke) = DevKeyCombo.parse(combo) else { return .drop(index: index, char: char) }
                return .key(index: index, char: char, stroke: stroke)
            }
            guard mode == .key else { return .insert(index: index, char: char) }
            guard let stroke = DevKeyCombo.printableStroke(scalar) else { return .drop(index: index, char: char) }
            return .key(index: index, char: char, stroke: stroke)
        }
        return Plan(mode: mode, steps: steps)
    }

    /// The reply body. `inserted` carries one flag per INSERT step, in order —
    /// whether the driver saw that insertion go through; a missing flag is a drop.
    /// Key steps have no result to report: they count in `chars` and are neither
    /// inserted nor dropped.
    public static func summary(of plan: Plan, inserted: [Bool]) -> JSONValue {
        var observations = inserted.makeIterator()
        var insertedCount = 0
        var dropped: [JSONValue] = []
        for step in plan.steps {
            switch step {
            case .insert(let index, let char):
                if observations.next() == true {
                    insertedCount += 1
                } else {
                    dropped.append(["index": .number(Double(index)), "char": .string(char)])
                }
            case .drop(let index, let char):
                dropped.append(["index": .number(Double(index)), "char": .string(char)])
            case .key:
                break
            }
        }
        return [
            "chars": .number(Double(plan.steps.count)),
            "inserted": .number(Double(insertedCount)),
            "dropped": .array(dropped),
            "mode": .string(plan.mode.rawValue),
        ]
    }

    private static let namedControls: [Unicode.Scalar: String] = [
        "\n": "enter", "\r": "enter", "\t": "tab", "\u{1B}": "escape", "\u{7F}": "backspace",
    ]

    private static func controlCombo(_ scalar: Unicode.Scalar) -> String? {
        if let named = namedControls[scalar] { return named }
        guard (0x01...0x1A).contains(scalar.value) else { return nil }
        return "ctrl+" + String(Unicode.Scalar(UInt8(0x60 + scalar.value)))
    }
}
