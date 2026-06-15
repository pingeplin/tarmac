import Foundation

/// Pure view-model for the ⌘K boards switcher (M3 P4, design ref board-v4.jsx
/// B5). Kept in TarmacKit so the prefix filter, the ⌘1..9 / ⏎ ordinal map, the
/// selection clamp, and the meta-line formatting are unit-tested away from
/// AppKit. `AppController` gathers the per-board facts (counts derive app-side —
/// `BoardMeta` carries none) into `BoardSummary`s, asks for `rows(...)`, and
/// renders the result; the 86×54 thumbnail reuses `BoardWayfinding`'s world→box
/// projection, so no geometry lives here.
///
/// This replaces the former `BoardRegistry` (next-in-order + ordinal): the ⌘K
/// switcher does not cycle, and its ⌘1..9 jump must address the *visible*
/// (filtered) rows, not the full board list.
public enum BoardSwitcher {
    /// One board's live facts, gathered by the app for the switcher. The app can
    /// derive these locally for boards it has visited (their cards + signals stay
    /// alive while backgrounded); a never-visited board reports `cards == 0` and
    /// `isLive == false` until its first restore.
    public struct BoardSummary: Equatable {
        public let boardID: String
        /// User-given display name, or nil → falls back to the slug `boardID`.
        public let name: String?
        /// Terminal cards with a live (cyan) foreground signal.
        public let running: Int
        /// Cards with an unacked bell (amber) signal.
        public let bell: Int
        /// Total cards on the board.
        public let cards: Int
        /// Whether the board has any live pty — drives the cyan-vs-faint strip
        /// glyph. (P4: attached ⇒ live; the honest detached signal is P5.)
        public let isLive: Bool

        public init(boardID: String, name: String?, running: Int, bell: Int, cards: Int, isLive: Bool) {
            self.boardID = boardID
            self.name = name
            self.running = running
            self.bell = bell
            self.cards = cards
            self.isLive = isLive
        }

        /// What the row shows: the display name, else the slug.
        public var display: String { name ?? boardID }
    }

    /// A switcher row ready to render: the resolved display label, the active
    /// flag (selected-style highlight is separate, driven by keyboard), the
    /// glyph/spinner inputs, and the formatted meta line.
    public struct BoardRow: Equatable {
        public let boardID: String
        public let display: String
        public let isActive: Bool
        public let isLive: Bool
        public let running: Int
        public let bell: Int
        public let cards: Int
        public let meta: String

        public init(boardID: String, display: String, isActive: Bool, isLive: Bool, running: Int, bell: Int, cards: Int, meta: String) {
            self.boardID = boardID
            self.display = display
            self.isActive = isActive
            self.isLive = isLive
            self.running = running
            self.bell = bell
            self.cards = cards
            self.meta = meta
        }
    }

    /// Builds the visible rows from the summaries, an `active` board id, and the
    /// typed `filter`. The filter is a case-insensitive **prefix** match on the
    /// display label (plan §6.2: prefix + row-order; fuzzy deferred); an empty
    /// filter keeps every board. Display order is preserved.
    public static func rows(summaries: [BoardSummary], active: String, filter: String) -> [BoardRow] {
        let q = filter.lowercased()
        return summaries
            .filter { q.isEmpty || $0.display.lowercased().hasPrefix(q) }
            .map { s in
                BoardRow(
                    boardID: s.boardID,
                    display: s.display,
                    isActive: s.boardID == active,
                    isLive: s.isLive,
                    running: s.running,
                    bell: s.bell,
                    cards: s.cards,
                    meta: meta(running: s.running, bell: s.bell, cards: s.cards)
                )
            }
    }

    /// The board id at 1-based ordinal `n` among the *visible* rows (⌘1..9 jump /
    /// ⏎ when the panel maps Enter to the highlighted row). nil when out of range.
    public static func boardID(forOrdinal n: Int, in rows: [BoardRow]) -> String? {
        guard n >= 1, n <= rows.count else { return nil }
        return rows[n - 1].boardID
    }

    /// Clamps a selection index into `[0, count-1]` (0 when empty) after a
    /// filter change or an ↑/↓ move — selection does not wrap.
    public static func clampSelection(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, index), count - 1)
    }

    // MARK: - P5.4 rename / delete validation (mirrors the daemon's authority)

    /// Whether a board may be deleted: only when more than one exists (a board set
    /// is never empty). Mirrors the daemon's last-board refusal so the switcher
    /// never even arms the delete confirm for the last board.
    public static func canDelete(boardCount: Int) -> Bool {
        boardCount > 1
    }

    /// Normalizes a typed rename: trims surrounding whitespace; a blank/whitespace-
    /// only name collapses to "" — which the daemon maps to "clear the name back to
    /// the slug" rather than setting a blank visible name.
    public static func sanitizedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a typed scalar should feed the switcher filter / rename buffer — a
    /// real printable character. Excludes control chars (< 0x20), DEL (0x7f), and
    /// the AppKit function/arrow/navigation keys, which `NSEvent.characters`
    /// delivers as private-use scalars in 0xF700–0xF8FF (e.g. NSUpArrowFunctionKey
    /// = 0xF700): without this they would otherwise be appended as garbage glyphs.
    public static func isTypable(scalar value: UInt32) -> Bool {
        value >= 0x20 && value != 0x7f && !(0xF700...0xF8FF).contains(value)
    }

    /// Resolve a board's switcher liveness from the app's local card signals and
    /// the daemon's reported live-pty count (`BoardMeta.running`, P5). For a board
    /// the app has **visited** this session the local signals are authoritative —
    /// its cards + live SwiftTerm views stay alive while backgrounded, so they do
    /// not flicker against the daemon's count. For a **never-visited** board (no
    /// local view yet — e.g. a board whose shells survived an app relaunch) the
    /// daemon's `running` count is the only honest source of liveness.
    public static func liveness(
        visited: Bool, localRunning: Int, localIsLive: Bool, daemonRunning: Int?
    ) -> (running: Int, isLive: Bool) {
        if visited { return (localRunning, localIsLive) }
        let r = max(0, daemonRunning ?? 0)
        return (r, r > 0)
    }

    /// The row meta line: `"N running · M bell · K cards"`, dropping the running
    /// and bell segments when zero; the card count is always shown (singular
    /// "1 card"). Matches B5's faint meta text — the leading ⠧ spinner and the
    /// glyph colors are the view's job.
    public static func meta(running: Int, bell: Int, cards: Int) -> String {
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if bell > 0 { parts.append("\(bell) bell") }
        parts.append(cards == 1 ? "1 card" : "\(cards) cards")
        return parts.joined(separator: " · ")
    }
}
