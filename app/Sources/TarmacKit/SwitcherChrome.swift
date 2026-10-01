/// What the ⌘K switcher panel says: the query bar, the per-row marks and the
/// footer. Fonts, colors and geometry are the view's.
public enum SwitcherChrome {
    public struct QueryBar: Equatable, Sendable {
        public var label: String
        /// The filter, or the rename buffer while renaming.
        public var text: String
        /// Shown in place of an empty `text`.
        public var placeholder: String

        public init(label: String, text: String, placeholder: String) {
            self.label = label
            self.text = text
            self.placeholder = placeholder
        }
    }

    public enum Footer: Equatable, Sendable {
        case hints
        case renameHints
        /// A delete is armed for the board with this label.
        case confirmDelete(String)

        public struct Run: Equatable, Sendable {
            public var text: String
            public var strong: Bool

            public init(_ text: String, strong: Bool = false) {
                self.text = text
                self.strong = strong
            }
        }

        public var runs: [Run] {
            switch self {
            case .hints: [Run("⏎ switch · ⌘N new · ⌘E rename · ⌘⌫ delete")]
            case .renameHints: [Run("⏎ confirm · esc cancel rename")]
            case .confirmDelete(let name):
                [Run("⌘⌫ again to delete "), Run("\"\(name)\"", strong: true), Run(" · esc cancel")]
            }
        }
    }

    public static let caret = "▌"
    public static let emptyList = "no boards match"
    /// Follows the active board's name.
    public static let activeMark = "●"

    public static func queryBar(_ state: SwitcherKeys.State) -> QueryBar {
        state.editing
            ? QueryBar(label: "rename:", text: state.editBuffer, placeholder: "rename…")
            : QueryBar(label: "⌘K", text: state.filter, placeholder: "switch to…")
    }

    /// The row's leading glyph. A live board shows one of four arcs picked from
    /// the clock when the row is drawn; nothing animates it.
    public static func liveGlyph(isLive: Bool, nowMs: UInt64) -> String {
        guard isLive else { return "○" }
        return ["◜", "◝", "◞", "◟"][Int(nowMs / 200 % 4)]
    }

    /// `⌘n` for the rows ⌘1–9 reach; `row` is the 0-based visible index.
    public static func ordinalHint(row: Int) -> String? {
        (0..<9).contains(row) ? "⌘\(row + 1)" : nil
    }

    public static func footer(_ state: SwitcherKeys.State, rows: [BoardSwitcher.BoardRow]) -> Footer {
        if state.confirmingDelete, rows.indices.contains(state.selected) {
            return .confirmDelete(rows[state.selected].display)
        }
        return state.editing ? .renameHints : .hints
    }
}
