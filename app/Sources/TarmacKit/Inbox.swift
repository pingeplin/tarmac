/// The inbox (spec 2611.0013): one list of what needs the user, on every
/// board. Report items follow the daemon's `term_report` frames; bell and exit
/// items are the app's own, and die with it. Pure: the clock is passed in.
///
/// It never touches a card: the chip, the bell dot and the pills show the
/// daemon's and the terminal's facts, and a dismissal hides an item here only.
public struct Inbox: Equatable, Sendable {
    public enum Family: String, Equatable, Hashable, Sendable {
        case report, bell, exit
    }

    /// One item for each terminal and family.
    public struct ItemID: Equatable, Hashable, Sendable {
        public let termID: String
        public let family: Family

        public init(termID: String, family: Family) {
            self.termID = termID
            self.family = family
        }
    }

    public enum Kind: Equatable, Sendable {
        case report(TermReport.Kind)
        case bell
        case exit(code: Int?)

        /// The pill signal the kind shows as, and so its colour.
        public var signal: CardSignal {
            switch self {
            case .report(.blocked): .blocked
            case .report(.done): .done
            case .bell: .bell
            case .exit: .exit
            }
        }

        public var family: Family {
            switch self {
            case .report: .report
            case .bell: .bell
            case .exit: .exit
            }
        }
    }

    public struct Item: Equatable, Sendable {
        public let kind: Kind
        public let termID: String
        public let boardID: String
        public let atMs: UInt64
        public let proc: String?
        public let cwd: String?
        /// A report's text; nil for a bell or an exit.
        public let text: String?
        public var read: Bool

        public var id: ItemID { ItemID(termID: termID, family: kind.family) }

        public init(
            kind: Kind, termID: String, boardID: String, atMs: UInt64, proc: String?, cwd: String?, text: String?,
            read: Bool
        ) {
            self.kind = kind
            self.termID = termID
            self.boardID = boardID
            self.atMs = atMs
            self.proc = proc
            self.cwd = cwd
            self.text = text
            self.read = read
        }
    }

    public enum Filter: String, CaseIterable, Equatable, Sendable {
        case all, reports, bell, exit

        public var next: Filter { Self.cycle(self, by: 1) }
        public var previous: Filter { Self.cycle(self, by: -1) }

        var family: Family? {
            switch self {
            case .all: nil
            case .reports: .report
            case .bell: .bell
            case .exit: .exit
            }
        }

        public func admits(_ kind: Kind) -> Bool {
            family == nil || family == kind.family
        }

        private static func cycle(_ filter: Filter, by step: Int) -> Filter {
            let all = Filter.allCases
            let index = all.firstIndex(of: filter)! + step + all.count
            return all[index % all.count]
        }
    }

    /// Over this, the oldest read item goes first, then the oldest item.
    public static let maxItems = 200

    private struct Entry: Equatable, Sendable {
        var item: Item
        /// When it was put: breaks a tie of `atMs`, newest first.
        var seq: Int
    }

    private var entries: [ItemID: Entry] = [:]
    private var nextSeq = 0
    /// The `atMs` of each item the user dismissed: a frame or an event with
    /// that `atMs` stays hidden, and a newer one shows again.
    private var dismissed: [ItemID: UInt64] = [:]
    /// A terminal cold-spawned in place of another at a board's first build.
    private var successors: [String: String] = [:]
    /// Terminals a board's first build found with no card and no successor.
    private var gone: Set<String> = []
    /// Terminals whose card the user closed: the daemon's `exit` for the
    /// SIGHUP comes after, and makes no row. Term ids are never reused.
    private var removed: Set<String> = []

    public init() {}

    // Every operation returns whether the store changed, so the app redraws
    // only then.

    /// A `term_report` frame: with a kind it puts the terminal's report item
    /// on the frame's board, else `fallbackBoard` (an older daemon), else
    /// nowhere; with none it removes the item.
    @discardableResult
    public mutating func apply(_ frame: TermReportFrame, fallbackBoard: String?) -> Bool {
        guard let report = frame.report else { return reportEnded(termID: frame.termID) }
        guard let boardID = frame.boardID ?? fallbackBoard else { return false }
        return put(Item(
            kind: .report(report.kind), termID: frame.termID, boardID: boardID, atMs: report.atMs, proc: report.proc,
            cwd: frame.cwd, text: report.text, read: report.read
        ))
    }

    @discardableResult
    public mutating func bell(termID: String, boardID: String, proc: String?, cwd: String?, nowMs: UInt64) -> Bool {
        put(Item(kind: .bell, termID: termID, boardID: boardID, atMs: nowMs, proc: proc, cwd: cwd, text: nil, read: false))
    }

    /// The terminal's report ended with no frame: it was lost, or it exited.
    @discardableResult
    public mutating func reportEnded(termID: String) -> Bool {
        entries.removeValue(forKey: ItemID(termID: termID, family: .report)) != nil
    }

    /// Every `exit` frame ends the report; a failed one
    /// (`TermExit.isFailure`) also puts an exit item.
    @discardableResult
    public mutating func exit(
        termID: String, boardID: String, code: Int?, proc: String?, cwd: String?, nowMs: UInt64
    ) -> Bool {
        let ended = reportEnded(termID: termID)
        guard TermExit.isFailure(code: code) else { return ended }
        let item = Item(
            kind: .exit(code: code), termID: termID, boardID: boardID, atMs: nowMs, proc: proc, cwd: cwd, text: nil,
            read: false
        )
        return put(item) || ended
    }

    /// The user touched the terminal: its bell and exit items are read. A
    /// report is read only by the daemon's word.
    @discardableResult
    public mutating func touch(termID: String) -> Bool {
        var changed = false
        for family in [Family.bell, .exit] {
            let id = ItemID(termID: termID, family: family)
            guard entries[id]?.item.read == false else { continue }
            entries[id]?.item.read = true
            changed = true
        }
        return changed
    }

    /// The card went: its rows go, and nothing it sends later makes one —
    /// the daemon's `exit` for a ⌘W comes after the card is gone. Term ids
    /// are never reused, so what else is kept for it goes too.
    @discardableResult
    public mutating func removeTerm(termID: String) -> Bool {
        removed.insert(termID)
        successors[termID] = nil
        gone.remove(termID)
        dismissed = dismissed.filter { $0.key.termID != termID }
        return keepEntries { $0.key.termID != termID }
    }

    /// Every board there is: an item of any other board goes.
    @discardableResult
    public mutating func keepBoards(_ ids: Set<String>) -> Bool {
        keepEntries { ids.contains($0.value.item.boardID) }
    }

    /// Reports come back with the daemon's replay; dismissals stay.
    @discardableResult
    public mutating func lostConnection() -> Bool {
        keepEntries { $0.key.family != .report }
    }

    /// A board was built for the first time, with the terminal `cards` and the
    /// cold spawns that replaced dead terminals. A bell or exit item whose
    /// terminal has neither a card nor a successor there has nothing to land on.
    @discardableResult
    public mutating func boardBuilt(boardID: String, cards: Set<String>, successors: [String: String]) -> Bool {
        self.successors.merge(successors) { _, new in new }
        let orphans = entries.values.map(\.item).filter {
            $0.boardID == boardID && $0.kind.family != .report && !cards.contains($0.termID)
                && successors[$0.termID] == nil
        }
        for item in orphans {
            gone.insert(item.termID)
            entries[item.id] = nil
        }
        return !orphans.isEmpty
    }

    /// The terminal a jump to `termID`'s item lands on: its successor, if a
    /// first build replaced it, else itself, unless that build found it gone.
    public func target(termID: String) -> String? {
        if let successor = successors[termID] { return successor }
        return gone.contains(termID) ? nil : termID
    }

    /// Hides the item until a newer `atMs` for it comes.
    @discardableResult
    public mutating func dismiss(_ id: ItemID) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        dismissed[id] = entry.item.atMs
        return true
    }

    /// Takes the item out, hiding nothing: a jump whose card went (S36).
    @discardableResult
    public mutating func remove(_ id: ItemID) -> Bool {
        entries.removeValue(forKey: id) != nil
    }

    /// Dismisses the read items that `filter` shows.
    @discardableResult
    public mutating func clearRead(_ filter: Filter) -> Bool {
        var changed = false
        for item in items(filter) where item.read {
            changed = dismiss(item.id) || changed
        }
        return changed
    }

    public func item(_ id: ItemID) -> Item? {
        entries[id]?.item
    }

    /// Newest first; on a tie of `atMs`, the item put later first.
    public func items(_ filter: Filter) -> [Item] {
        entries.values
            .filter { filter.admits($0.item.kind) }
            .sorted { ($0.item.atMs, $0.seq) > ($1.item.atMs, $1.seq) }
            .map(\.item)
    }

    public var unreadCount: Int {
        entries.values.filter { !$0.item.read }.count
    }

    public func unreadReports(board: String) -> Int {
        entries.values.filter { $0.item.kind.family == .report && $0.item.boardID == board && !$0.item.read }.count
    }

    public func exitUnread(termID: String) -> Bool {
        entries[ItemID(termID: termID, family: .exit)].map { !$0.item.read } ?? false
    }

    /// An item with the `atMs` it already has keeps its place, so a report
    /// marked read does not move.
    private mutating func put(_ item: Item) -> Bool {
        let id = item.id
        guard !removed.contains(item.termID) else { return false }
        if dismissed[id] == item.atMs { return entries.removeValue(forKey: id) != nil }
        if let entry = entries[id], entry.item.atMs == item.atMs {
            guard entry.item != item else { return false }
            entries[id]?.item = item
            return true
        }
        entries[id] = Entry(item: item, seq: nextSeq)
        nextSeq += 1
        trim()
        return true
    }

    private mutating func keepEntries(_ keep: ((key: ItemID, value: Entry)) -> Bool) -> Bool {
        let before = entries.count
        entries = entries.filter(keep)
        return entries.count != before
    }

    private mutating func trim() {
        while entries.count > Self.maxItems {
            let oldest = entries.values.sorted { ($0.item.atMs, $0.seq) < ($1.item.atMs, $1.seq) }
            guard let victim = oldest.first(where: \.item.read) ?? oldest.first else { return }
            entries[victim.item.id] = nil
        }
    }
}
