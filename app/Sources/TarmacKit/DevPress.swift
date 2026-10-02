import Foundation

/// What `tarmac dev press <combo>` parses and refuses (spec 2609.0018, #183) —
/// the Swift twin of `desktop/src-tauri/src/dev_press.rs`, plus the flag ranges
/// its command re-checks. Posting the event is the app's.
public enum DevPress {
    /// A ⌘ chord as AppKit takes it: raw `NSEvent.ModifierFlags` bits, the
    /// characters the event carries, and the US layout's key code.
    public struct Chord: Equatable, Sendable {
        public var flags: UInt64
        public var characters: String
        public var keyCode: UInt16

        public init(flags: UInt64, characters: String, keyCode: UInt16) {
            self.flags = flags
            self.characters = characters
            self.keyCode = keyCode
        }
    }

    public struct Plan: Equatable, Sendable {
        public var chord: Chord
        /// How long the key reads as held to the ⌘Q guard's release poll.
        public var holdMs: UInt64
        /// How far in the past the press is stamped.
        public var ageMs: UInt64
        /// How long the main thread is frozen behind the posted key.
        public var busyMs: UInt64?

        public init(chord: Chord, holdMs: UInt64, ageMs: UInt64, busyMs: UInt64?) {
            self.chord = chord
            self.holdMs = holdMs
            self.ageMs = ageMs
            self.busyMs = busyMs
        }
    }

    /// A press that names no `--hold`. Long enough that a double tap quits on
    /// release, as a real one does, not on the first poll.
    public static let tapHoldMs: UInt64 = 100
    /// How long activation may take to key the window, and how often to look.
    public static let keyWaitMs = 1_000
    public static let keyPollMs = 20

    /// The flags are checked first: the wire accepts any integer, and the CLI
    /// has already refused these, so a miss here is a hand-built frame.
    public static func plan(combo: String, holdMs: Int?, ageMs: Int?, busyMs: Int?) -> Result<Plan, DevError> {
        let inRange = (holdMs.map((1...DevRequest.holdMsMax).contains) ?? true)
            && (ageMs.map((0...DevRequest.ageMsMax).contains) ?? true)
            && (busyMs.map((1...DevRequest.busyMsMax).contains) ?? true)
            && !(busyMs != nil && ageMs != nil)
        guard inRange else {
            return .failure(DevError(.badRequest, "hold, age or busy out of range, or busy with age"))
        }
        return parse(combo).map { chord in
            Plan(
                chord: chord,
                holdMs: holdMs.map(UInt64.init) ?? tapHoldMs,
                ageMs: ageMs.map(UInt64.init) ?? 0,
                busyMs: busyMs.map(UInt64.init)
            )
        }
    }

    /// `cmd` plus any of `shift`, `alt`, `ctrl` (each at most once, any order),
    /// then one ASCII lowercase letter or digit. Every `bad_combo` rule is
    /// checked before `cmd` is looked for, so `unsupported_combo` always means a
    /// well-formed chord without it.
    public static func parse(_ combo: String) -> Result<Chord, DevError> {
        func bad(_ what: String) -> Result<Chord, DevError> {
            .failure(DevError(.badCombo, "\(what) in `\(combo)`; the grammar is cmd[+shift][+alt][+ctrl]+<a-z|0-9>"))
        }
        let parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var flags: UInt64 = 0
        for name in parts.dropLast() {
            guard let bit = modifiers[name] else { return bad(name.isEmpty ? "empty segment" : "unknown modifier") }
            guard flags & bit == 0 else { return bad("repeated modifier") }
            flags |= bit
        }
        let base = parts[parts.count - 1].unicodeScalars
        guard base.count == 1, let scalar = base.first,
              ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar),
              let key = DevKeyCombo.physicalKey(for: scalar)
        else { return bad("the base must be one lowercase letter or digit") }
        guard flags & QuitShortcut.command != 0 else {
            return .failure(DevError(
                .unsupportedCombo, "`\(combo)` has no cmd; `tarmac dev key` / `type` drive non-⌘ keys through the terminal"
            ))
        }
        let face = flags & QuitShortcut.shift != 0 ? scalar.properties.uppercaseMapping : String(scalar)
        return .success(Chord(flags: flags, characters: face, keyCode: key.keyCode))
    }

    /// Would AppKit hand this chord to an item carrying `keyEquivalent` and
    /// `mask`? True iff the characters match ignoring ASCII case and the chord's
    /// modifiers are exactly the ones the guard itself expects of a press on
    /// that item.
    public static func matchesItem(_ chord: Chord, keyEquivalent: String, mask: UInt64) -> Bool {
        asciiLowercased(keyEquivalent) == asciiLowercased(chord.characters)
            && chord.flags == QuitShortcut.expectedModifiers(keyEquivalent: keyEquivalent, mask: mask)
    }

    /// The posted event's timestamp: `ageMs` before `nowMs` on the uptime
    /// clock, stopping at zero rather than wrapping into the future.
    public static func pressMs(nowMs: UInt64, ageMs: UInt64) -> UInt64 {
        nowMs > ageMs ? nowMs - ageMs : 0
    }

    public static func reply(combo: String, pressMs: UInt64, plan: Plan, activated: Bool) -> JSONValue {
        [
            "combo": .string(combo),
            "press_ms": .number(Double(pressMs)),
            "hold_ms": .number(Double(plan.holdMs)),
            "activated": .bool(activated),
            "busy_ms": plan.busyMs.map { .number(Double($0)) } ?? .null,
        ]
    }

    public static func notRetargeted(combo: String) -> DevError {
        DevError(
            .notRetargeted,
            "`\(combo)` would reach a native terminate: item, or a Quit item with no guard behind it; not posted"
        )
    }

    public static let notKey = DevError(
        .notKey, "activation was refused (a locked screen?); click the dev window and re-run"
    )

    private static let modifiers: [String: UInt64] = [
        "cmd": QuitShortcut.command, "shift": QuitShortcut.shift,
        "alt": QuitShortcut.option, "ctrl": QuitShortcut.control,
    ]

    private static func asciiLowercased(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 0x20) ?? $0 : $0 }
    }
}
