import Foundation

/// Every decision the ⌘Q guard makes (spec 2609.0016). No AppKit types cross
/// this line: the event's raw modifier bits, the Quit item's live key
/// equivalent, the clock and the key state are all passed in, so the hold
/// threshold, the second-tap window and the keyboard-Quit test are unit-tested
/// away from AppKit. The wiring (`NSMenuItem` retarget, the poll timer, the
/// notice panel) only applies the `Effect`s this returns.
///
/// Timestamps are whole milliseconds on one clock — `NSEvent.timestamp` (seconds
/// since boot, sleep excluded) and the wiring's `now` must both come from it, so
/// that an event's age is a plain subtraction.
public struct QuitGuard: Equatable, Sendable {
    /// How long Q must be held before the gesture is committed. Chromium's
    /// `kShowDuration` 1.5 s minus its 1.0 s fuzz (`confirm_quit_panel_controller.mm`).
    public static let holdMs: UInt64 = 500
    /// A second ⌘Q this soon after the PREVIOUS PRESS quits, as in Chromium.
    public static let secondTapMs: UInt64 = 1_000
    /// How stale `[NSApp currentEvent]` may be and still count as the keypress
    /// that triggered the item. It must outlast a busy web process's round trip,
    /// because WebKit only re-sends the keyDown to the menu after the page has
    /// left it unhandled.
    public static let freshnessBoundMs: Int64 = 2_000
    /// Key-state sampling period. Q's keyUp never arrives while ⌘ is held.
    public static let pollMs: UInt64 = 50
    /// How long the notice stays up after an early release, and its fade.
    public static let lingerMs: UInt64 = 1_000
    public static let fadeMs: UInt64 = 200
    /// Ten alpha steps over `fadeMs` read as a fade and need no Core Animation,
    /// whose completion handler would have to be generation-guarded anyway.
    public static let fadeSteps = 10
    public static var fadeStepMs: UInt64 { fadeMs / UInt64(fadeSteps) }

    public enum Phase: Equatable, Sendable {
        case idle(lastStartMs: UInt64?)
        case showing(startedMs: UInt64)
        case confirming

        /// The word the QA driver's snapshot reports (spec 2609.0018).
        public var name: String {
            switch self {
            case .idle: return "idle"
            case .showing: return "showing"
            case .confirming: return "confirming"
            }
        }
    }

    public enum Route: Equatable, Sendable {
        case terminateNow
        case guarded

        public var name: String {
            switch self {
            case .guarded: return "guard"
            case .terminateNow: return "terminate"
            }
        }
    }

    public enum Effect: Equatable, Sendable {
        case showHud
        case lingerThenFadeHud
        /// Hides the cockpit AND cancels any pending linger or fade: past the
        /// threshold the notice stays up over the hidden window until the app
        /// exits, and a second tap inherits the first tap's notice.
        case hideWindows
        case startPolling(keyCode: UInt16)
        case stopPolling
        case exit
    }

    /// What the handler read off `[NSApp currentEvent]` and the Quit item that
    /// invoked it.
    public struct Event: Equatable, Sendable {
        public var isKeyDown: Bool
        public var modifiers: UInt64
        public var itemMask: UInt64
        public var itemKeyEquivalent: String
        public var ageMs: Int64

        public init(isKeyDown: Bool, modifiers: UInt64, itemMask: UInt64, itemKeyEquivalent: String, ageMs: Int64) {
            self.isKeyDown = isKeyDown
            self.modifiers = modifiers
            self.itemMask = itemMask
            self.itemKeyEquivalent = itemKeyEquivalent
            self.ageMs = ageMs
        }
    }

    /// The wiring acts on the effects, never on the phase; tests and the QA
    /// snapshot read it.
    public private(set) var phase: Phase = .idle(lastStartMs: nil)

    /// The last keyDown timestamp that drove the machine. WebKit can re-send the
    /// same `NSEvent` object, and a second delivery must not advance the gesture.
    private var lastPressMs: UInt64?

    public init() {}

    /// Guard iff this really is the Quit KEYPRESS and either a gesture is already
    /// running or the toggle is on. Everything else — a menu click, a stale
    /// `currentEvent`, someone else's chord — quits at once.
    public func route(_ event: Event, enabled: Bool) -> Route {
        let idle: Bool
        if case .idle = phase { idle = true } else { idle = false }
        return Self.isKeyboardQuit(event) && (!idle || enabled) ? .guarded : .terminateNow
    }

    /// A keyDown delivered to the retargeted Quit item. `pressMs` is the event's
    /// own timestamp, so the hold and the second-tap window count from the
    /// physical press rather than from the handler, which WebKit can reach a
    /// whole web-process round trip later.
    public mutating func onQuitKey(pressMs: UInt64, keyCode: UInt16, isRepeat: Bool) -> [Effect] {
        if isRepeat || lastPressMs == pressMs { return [] }
        lastPressMs = pressMs
        switch phase {
        case .idle(let lastStartMs):
            if let start = lastStartMs, pressMs >= start, pressMs - start < Self.secondTapMs {
                phase = .confirming
                return [.hideWindows, .startPolling(keyCode: keyCode)]
            }
            phase = .showing(startedMs: pressMs)
            return [.showHud, .startPolling(keyCode: keyCode)]
        case .showing:
            // Re-pressed before a poll saw the release: a second tap. No
            // `.startPolling` — the poller is already running on the first
            // chord's key, which is the key still physically down.
            phase = .confirming
            return [.hideWindows]
        case .confirming:
            return []
        }
    }

    /// One key-state sample. The wiring takes it on the main thread and stops
    /// polling the moment `.stopPolling` is applied, so a sample always belongs
    /// to the phase it lands in — and, since `route` never guards a press from
    /// the future, it is never older than the press that started the gesture.
    public mutating func onPoll(sampledMs: UInt64, keyDown: Bool) -> [Effect] {
        switch phase {
        case .idle:
            return []
        case .showing(let startedMs):
            guard keyDown else {
                phase = .idle(lastStartMs: startedMs)
                return [.lingerThenFadeHud, .stopPolling]
            }
            let heldMs = sampledMs > startedMs ? sampledMs - startedMs : 0
            guard heldMs >= Self.holdMs else { return [] }
            phase = .confirming
            return [.hideWindows]
        case .confirming:
            if keyDown { return [] }
            phase = .idle(lastStartMs: nil)
            return [.stopPolling, .exit]
        }
    }

    /// Whether the event that invoked the Quit item is the keypress for its
    /// shortcut. AppKit already decided that the chord matches; this only rules
    /// out the events that reach the item some other way — a mouse click,
    /// keyboard menu navigation's Return, a VoiceOver press whose `currentEvent`
    /// is older.
    private static func isKeyboardQuit(_ event: Event) -> Bool {
        event.isKeyDown
            && !event.itemKeyEquivalent.isEmpty
            && (event.modifiers & QuitShortcut.matched)
                == QuitShortcut.expectedModifiers(keyEquivalent: event.itemKeyEquivalent, mask: event.itemMask)
            && (0...freshnessBoundMs).contains(event.ageMs)
    }

    /// Opacity of the notice after `step` of `fadeSteps` fade steps.
    public static func fadeAlpha(step: Int) -> Double {
        1 - Double(step) / Double(fadeSteps)
    }

    /// `NSEvent.timestamp` (seconds since boot) as whole milliseconds. A zero,
    /// negative or NaN timestamp saturates to 0, which the freshness check then
    /// rejects as ancient — both are seen in the field. Saturates rather than
    /// converting directly, because `UInt64(Double)` traps on those.
    public static func pressMs(timestampSeconds: Double) -> UInt64 {
        let ms = timestampSeconds * 1_000
        guard ms > 0 else { return 0 }
        guard ms < Double(UInt64.max) else { return .max }
        return UInt64(ms)
    }

    /// The event's age. Signed, because a bogus timestamp from the future is a
    /// thing that happens in the field and a `UInt64` subtraction would trap on
    /// it. A timestamp too large for `Int64` clamps, staying in the future.
    public static func ageMs(nowMs: UInt64, pressMs: UInt64) -> Int64 {
        Int64(clamping: nowMs) - Int64(clamping: pressMs)
    }
}

/// The Quit shortcut as the menu item carries it: the key equivalent plus the
/// modifier mask, in raw `NSEvent.ModifierFlags` bits.
public enum QuitShortcut {
    // `NSEvent.ModifierFlags` raw bits, restated so the kit needs no AppKit.
    public static let shift: UInt64 = 1 << 17
    public static let control: UInt64 = 1 << 18
    public static let option: UInt64 = 1 << 19
    public static let command: UInt64 = 1 << 20

    /// The only bits a shortcut match may consider. Caps Lock, Fn, NumericPad and
    /// Help ride along on a perfectly ordinary ⌘Q and must never break it.
    static let matched: UInt64 = shift | control | option | command

    /// The chord the item carries. A remap can put Shift in the key equivalent's
    /// character instead of the mask (Chromium `nsmenuitem_additions.mm`).
    public static func expectedModifiers(keyEquivalent: String, mask: UInt64) -> UInt64 {
        var wanted = mask & matched
        if carriesShift(keyEquivalent) { wanted |= shift }
        return wanted
    }

    /// The shortcut as the menu bar prints it.
    public static func label(keyEquivalent: String, mask: UInt64) -> String {
        let wanted = expectedModifiers(keyEquivalent: keyEquivalent, mask: mask)
        let glyphs: [(bit: UInt64, glyph: String)] = [(control, "⌃"), (option, "⌥"), (shift, "⇧"), (command, "⌘")]
        let modifiers = glyphs.filter { wanted & $0.bit != 0 }.map(\.glyph).joined()
        return modifiers + keyEquivalent.unicodeScalars.map { $0.properties.uppercaseMapping }.joined()
    }

    public static func noticeText(keyEquivalent: String, mask: UInt64) -> String {
        "Hold \(label(keyEquivalent: keyEquivalent, mask: mask)) to Quit"
    }

    /// Only a one-scalar key equivalent can carry Shift in its character: a
    /// function-key equivalent must not have ⇧ invented for it. Scalar-wise on
    /// purpose, with the Unicode lowercase mapping, so "ß" (which has no
    /// distinct lowercase) is not a shifted key.
    private static func carriesShift(_ keyEquivalent: String) -> Bool {
        let scalars = keyEquivalent.unicodeScalars
        guard let first = scalars.first, scalars.count == 1 else { return false }
        return first.properties.lowercaseMapping.unicodeScalars.first != first
    }
}
