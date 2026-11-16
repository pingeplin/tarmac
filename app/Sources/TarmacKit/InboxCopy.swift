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

    public static func quote(_ item: Inbox.Item) -> String? {
        item.text.map { "“\(oneLine($0))”" }
    }

    /// `<board> › <terminal> · <cwd>`: the board's name or id; the card's
    /// label, else the process, else `shell`; a folder under `home` as `~`.
    public static func place(_ item: Inbox.Item, boardName: String?, cardLabel: String?, home: String) -> String {
        let head = "\(boardName ?? item.boardID) › \(cardLabel ?? item.proc ?? TermLabel.initial)"
        guard let cwd = item.cwd else { return head }
        return "\(head) · \(tilde(cwd, home: home))"
    }

    public static func age(_ item: Inbox.Item, nowMs: UInt64) -> String {
        ChromeText.reportAge(atMs: item.atMs, nowMs: nowMs)
    }

    /// Every run of whitespace, newlines included, as one space; trimmed.
    public static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func tilde(_ path: String, home: String) -> String {
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }
}

/// The title-bar button's title.
public enum InboxBadge {
    public static func text(unread: Int) -> String {
        switch unread {
        case ...0: "inbox"
        case ...99: "inbox · \(unread)"
        default: "inbox · 99+"
        }
    }
}
