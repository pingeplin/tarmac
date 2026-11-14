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

        public func admits(_ kind: Kind) -> Bool {
            switch self {
            case .all: true
            case .reports: kind.family == .report
            case .bell: kind.family == .bell
            case .exit: kind.family == .exit
            }
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

    /// A `term_report` frame: with a kind it puts the terminal's report item
    /// on the frame's board, else `fallbackBoard` (an older daemon), else
    /// nowhere; with none it removes the item.
    public mutating func apply(_ frame: TermReportFrame, fallbackBoard: String?) {
        let id = ItemID(termID: frame.termID, family: .report)
        guard let report = frame.report else {
            entries[id] = nil
            return
        }
        guard let boardID = frame.boardID ?? fallbackBoard else { return }
        put(Item(
            kind: .report(report.kind), termID: frame.termID, boardID: boardID, atMs: report.atMs, proc: report.proc,
            cwd: frame.cwd, text: report.text, read: report.read
        ))
    }

    public mutating func bell(termID: String, boardID: String, proc: String?, cwd: String?, nowMs: UInt64) {
        put(Item(kind: .bell, termID: termID, boardID: boardID, atMs: nowMs, proc: proc, cwd: cwd, text: nil, read: false))
    }

    /// The terminal's report ended with no frame: it was lost, or it exited.
    public mutating func reportEnded(termID: String) {
        entries[ItemID(termID: termID, family: .report)] = nil
    }

    /// Every `exit` frame ends the report; one that `TermExitToast` names
    /// also puts an exit item.
    public mutating func exit(termID: String, boardID: String, code: Int?, proc: String?, cwd: String?, nowMs: UInt64) {
        reportEnded(termID: termID)
        guard TermExitToast.title(code: code) != nil else { return }
        put(Item(kind: .exit(code: code), termID: termID, boardID: boardID, atMs: nowMs, proc: proc, cwd: cwd, text: nil, read: false))
    }

    /// The user touched the terminal: its bell and exit items are read. A
    /// report is read only by the daemon's word.
    public mutating func touch(termID: String) {
        for family in [Family.bell, .exit] {
            entries[ItemID(termID: termID, family: family)]?.item.read = true
        }
    }

    public mutating func removeTerm(termID: String) {
        removed.insert(termID)
        entries = entries.filter { $0.key.termID != termID }
    }

    public mutating func removeBoard(boardID: String) {
        entries = entries.filter { $0.value.item.boardID != boardID }
    }

    /// Every board there is: an item of any other board goes.
    public mutating func keepBoards(_ ids: Set<String>) {
        entries = entries.filter { ids.contains($0.value.item.boardID) }
    }

    /// Reports come back with the daemon's replay; dismissals stay.
    public mutating func lostConnection() {
        entries = entries.filter { $0.key.family != .report }
    }

    /// A board was built for the first time, with the terminal `cards` and the
    /// cold spawns that replaced dead terminals. A bell or exit item whose
    /// terminal has neither a card nor a successor there has nothing to land on.
    public mutating func boardBuilt(boardID: String, cards: Set<String>, successors: [String: String]) {
        self.successors.merge(successors) { _, new in new }
        let orphans = entries.values.map(\.item).filter {
            $0.boardID == boardID && $0.kind.family != .report && !cards.contains($0.termID)
                && successors[$0.termID] == nil
        }
        for item in orphans {
            gone.insert(item.termID)
            entries[item.id] = nil
        }
    }

    /// The terminal a jump to `termID`'s item lands on: its successor, if a
    /// first build replaced it, else itself, unless that build found it gone.
    public func target(termID: String) -> String? {
        if let successor = successors[termID] { return successor }
        return gone.contains(termID) ? nil : termID
    }

    public mutating func dismiss(_ id: ItemID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        dismissed[id] = entry.item.atMs
    }

    /// Dismisses the read items that `filter` shows.
    public mutating func clearRead(_ filter: Filter) {
        for item in items(filter) where item.read {
            dismiss(item.id)
        }
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
    private mutating func put(_ item: Item) {
        let id = item.id
        guard !removed.contains(item.termID) else { return }
        if dismissed[id] == item.atMs {
            entries[id] = nil
            return
        }
        if let entry = entries[id], entry.item.atMs == item.atMs {
            entries[id]?.item = item
            return
        }
        entries[id] = Entry(item: item, seq: nextSeq)
        nextSeq += 1
        trim()
    }

    private mutating func trim() {
        while entries.count > Self.maxItems {
            let oldest = entries.values.sorted { ($0.item.atMs, $0.seq) < ($1.item.atMs, $1.seq) }
            guard let victim = oldest.first(where: \.item.read) ?? oldest.first else { return }
            entries[victim.item.id] = nil
        }
    }
}
