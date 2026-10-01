import AppKit
import SwiftTerm
import TarmacKit

/// One board (workspace) — the unit the app holds N of (M3 "strips = boards").
/// It owns the board-scoped state that used to live directly on the 1300-line
/// `AppController` god-object: its own `BoardView` (the infinite whiteboard),
/// its terminal sessions, and the prime / dock / shelf / provenance / fresh-card
/// state plus the per-board restore latch.
///
/// This is a **state + view-ownership container, not a behavioral object**.
/// `AppController` stays the coordinator — it owns the `DaemonClient`, the key
/// monitor, the window, the shared chrome singletons, and the global `DocStore`
/// — and drives the active board by reading/writing `activeBoard.<field>`. The
/// `TerminalSession`s live here, but they are *created* by
/// `AppController.makeSession` (the SwiftTerm delegate bridge holds a weak ref
/// back to the controller for input routing), so terminal I/O stays
/// controller-centric. Only the active board's `view` is mounted in `RootView`;
/// a backgrounded board keeps its cards + live SwiftTerm views detached so its
/// daemon ptys stay live (P3 §3).
@MainActor
final class Board {
    /// The single implicit board's id — today's desk migrates to this losslessly
    /// (mirrors the daemon's `DEFAULT_BOARD_ID`).
    static let defaultID = "board-0"

    let boardID: String
    /// User-given display name (nil until named — manual naming only, M3
    /// decision 3); the switcher falls back to the slug `boardID`.
    var name: String?
    /// This board's whiteboard. One `BoardView` per board.
    let view: BoardView
    /// This board's doc registry (dock order, per-doc read/recency state). A
    /// board is a workspace with its OWN docs — the daemon keeps a Registry per
    /// board and sends each board's docs in its own restore, so the store is
    /// per-board (a switch swaps which store drives the chrome). The file watcher
    /// stays global daemon-side; per-board is only the app-side mirror.
    let store = DocStore()

    /// Every terminal card's live state, keyed by `term_id` (Phase 5b: the board
    /// holds N of these).
    var sessions: [String: TerminalSession] = [:]
    /// Terminal ids in spawn order — the stable order ⌥tab cycles through.
    var sessionOrder: [String] = []
    /// The prime (focused) terminal card's id, or nil when no terminal is live.
    var primeTermID: String?

    /// Whether this board's focused terminal is docked into the cockpit pane.
    /// The dock *pane* is a `RootView` singleton shared across boards, so only
    /// the active (mounted) board is ever docked-into-the-pane at once; this flag
    /// records each board's intent so a switch can undock-on-leave / redock-on-
    /// arrive (P3 §3).
    var docked = false

    /// Shelf membership in chip order (open-but-unplaced docs).
    var shelfPaths: [String] = []
    /// Provenance: doc path → the `term_id` that opened it (from `DocEntry`).
    var docOwner: [String: String] = [:]
    /// Path of the most-recent fresh (just-landed CLI) card while it is still
    /// fresh; esc targets it for the shelf.
    var freshCardPath: String?
    /// The viewport to fly back to when esc follows a Return flight.
    var preFlightViewport: Viewport?

    /// True once this board's first restore has been applied. Per-board because
    /// the daemon sends a restore for the active board on connect and again on
    /// every `board_switch` — each board latches independently (P3 §7).
    var didInitialRestore = false

    init(boardID: String, name: String? = nil, view: BoardView) {
        self.boardID = boardID
        self.name = name
        self.view = view
    }

    // MARK: - Computed accessors (pure functions of this board's state)

    /// The prime terminal's session, or nil when no prime id is set.
    var primeSession: TerminalSession? {
        guard let id = primeTermID else { return nil }
        return sessions[id]
    }

    /// The prime terminal's SwiftTerm view (the one that receives keyboard input).
    var primeTerminalView: TerminalView? { primeSession?.view }

    /// The prime terminal's board card (the focused terminal), or nil.
    var primeTermCard: CardView? {
        guard let id = primeTermID else { return nil }
        return view.card(.term(id))
    }

    /// Whether the prime terminal is backed by a live pty — drives doc-card
    /// quieting and the dock/cycle guards.
    var hasLivePrime: Bool { primeSession?.live == true }

    /// Doc paths currently on this board.
    var boardDocPaths: [String] {
        view.cards.keys.compactMap {
            if case .doc(let path) = $0 { return path }
            return nil
        }
    }
}
