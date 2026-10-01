/// How a terminal card's mouse selection coexists with a program that tracks the
/// mouse (#154). The card re-applies these on every mouse event, since the
/// program can toggle tracking at any time.
public enum TermMouseSelect {
    /// The mouse-tracking mode the program has requested (DEC private modes 9,
    /// 1000, 1002 and 1003).
    public enum TrackingMode: Equatable, Sendable {
        case none, x10, vt200, drag, any
    }

    public struct Options: Equatable, Sendable {
        /// ⌥-drag forces a selection instead of reporting the drag to the program.
        /// Only while tracking is on: with no tracking ⌥-drag stays the shell's
        /// column select, which forcing a selection would turn off.
        public var optionDragForcesSelection: Bool
        /// A quick ⌥-click moves the shell's cursor by sending arrow keys. Shell-only:
        /// sent to a program that tracks the mouse they would drive the program
        /// (Claude Code's ↑ walks history).
        public var optionClickMovesCursor: Bool

        public init(optionDragForcesSelection: Bool, optionClickMovesCursor: Bool) {
            self.optionDragForcesSelection = optionDragForcesSelection
            self.optionClickMovesCursor = optionClickMovesCursor
        }
    }

    public static func options(for mode: TrackingMode) -> Options {
        let tracking = mode != .none
        return Options(optionDragForcesSelection: tracking, optionClickMovesCursor: !tracking)
    }

    /// Whether a mouse move is kept from the terminal. A terminal clears its
    /// selection on any user input, and every hover report counts; only any-event
    /// tracking (`?1003h`) reports hover, so under it a buttonless move is
    /// swallowed while a selection is shown. The cost, under any-event tracking
    /// only: no hover reports or link underline while a selection is shown; a plain
    /// click dismisses it and reports resume.
    public static func swallowsHover(mode: TrackingMode, buttons: Int, hasSelection: Bool) -> Bool {
        mode == .any && buttons == 0 && hasSelection
    }
}
