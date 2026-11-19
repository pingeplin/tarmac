/// One inbox row, as the panel draws it.
public struct InboxRow: Equatable, Sendable {
    public let id: Inbox.ItemID
    public let kind: Inbox.Kind
    public let title: String
    public let quote: InlineText?
    public let place: String
    public let age: String
    public let read: Bool
    public let toolTip: String
}

/// What an inbox row says (spec 2611.0013). A report is placed in time only,
/// and its text is quoted as a claim, as on the card's chip.
public enum InboxCopy {
    public static let empty = "no items"
    public static let footer = "↑↓ move · ↵ go · ⌫ remove · esc close"

    public static func filterName(_ filter: Inbox.Filter) -> String {
        filter.rawValue
    }

    public static func tag(_ kind: Inbox.Kind) -> String {
        kind.signal.rawValue
    }

    public static func title(_ item: Inbox.Item) -> String {
        switch item.kind {
        case .report: ReportChip.heading(proc: item.proc)
        case .bell: ChromeText.during("bell", proc: item.proc)
        case .exit(let code): TermExitToast.title(code: code) ?? "exit"
        }
    }

    /// The row's tool tip: the title, the whole text as it was sent, quoted,
    /// and the place.
    public static func toolTip(_ item: Inbox.Item, place: String) -> String {
        ([title(item)] + [item.text.map { "“\($0)”" }].compactMap { $0 } + [place]).joined(separator: "\n")
    }

    public static func quote(_ item: Inbox.Item) -> InlineText? {
        item.text.map { InlineMarkdown.line($0).quoted }
    }

    /// `<board> › <terminal> · <cwd>`: the board's name or id; the card's
    /// label, else the process, else `shell`; a folder under `home` as `~`.
    public static func place(_ item: Inbox.Item, boardName: String?, cardLabel: String?, home: String) -> String {
        let head = "\(boardName ?? item.boardID) › \(cardLabel ?? item.proc ?? TermLabel.initial)"
        guard let cwd = item.cwd else { return head }
        return "\(head) · \(ChromeText.tilde(cwd, home: home))"
    }

    public static func age(_ item: Inbox.Item, nowMs: UInt64) -> String {
        ChromeText.reportAge(atMs: item.atMs, nowMs: nowMs)
    }

    /// The whole row; the shell looks up the board's name and the card's
    /// label, and passes the home folder and the clock.
    public static func row(
        _ item: Inbox.Item, boardName: String?, cardLabel: String?, home: String, nowMs: UInt64
    ) -> InboxRow {
        let place = place(item, boardName: boardName, cardLabel: cardLabel, home: home)
        return InboxRow(
            id: item.id, kind: item.kind, title: title(item), quote: quote(item), place: place,
            age: age(item, nowMs: nowMs), read: item.read, toolTip: toolTip(item, place: place)
        )
    }
}
