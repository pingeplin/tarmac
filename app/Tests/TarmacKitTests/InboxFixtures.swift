@testable import TarmacKit

func inboxItem(
    _ kind: Inbox.Kind = .bell, proc: String? = nil, cwd: String? = nil, text: String? = nil,
    board: String = "board-1", at: UInt64 = 0, term: String = "T", read: Bool = false
) -> Inbox.Item {
    Inbox.Item(kind: kind, termID: term, boardID: board, atMs: at, proc: proc, cwd: cwd, text: text, read: read)
}
