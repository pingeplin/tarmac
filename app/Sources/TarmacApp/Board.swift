import AppKit
import TarmacKit
import TarmacTerm

/// One board (workspace) — the unit the app holds N of. It owns the
/// board-scoped state: its own `BoardView` (the infinite whiteboard), its doc
/// registry, its terminal sessions, and the prime / provenance state plus the
/// per-board restore latch.
///
/// This is a **state + view-ownership container, not a behavioral object**.
/// `AppController` stays the coordinator — it owns the `DaemonClient`, the key
/// monitor, the window and the shared chrome — and drives the active board by
/// reading/writing `activeBoard.<field>`. The `TerminalSession`s live here,
/// but they are *created* by `AppController.makeSession` (each view's
/// callbacks hold a weak ref back to the controller for input routing), so
/// terminal I/O stays controller-centric. Only the active board's `view` is
/// mounted in `RootView`; a backgrounded board keeps its cards + live terminal
/// views detached so its daemon ptys stay live.
@MainActor
final class Board {
    /// The single implicit board's id — today's desk migrates to this losslessly
    /// (mirrors the daemon's `DEFAULT_BOARD_ID`).
    static let defaultID = "board-0"

    let boardID: String
    /// User-given display name (nil until named — naming is manual only); the
    /// switcher falls back to the slug `boardID`.
    var name: String?
    /// This board's whiteboard. One `BoardView` per board.
    let view: BoardView
    /// This board's doc registry (the daemon's order, per-doc state). A
    /// board is a workspace with its OWN docs — the daemon keeps a Registry per
    /// board and sends each board's docs in its own restore, so the store is
    /// per-board (a switch swaps which store drives the chrome). The file watcher
    /// stays global daemon-side; per-board is only the app-side mirror.
    let store = DocStore()

    /// Every terminal card's state, keyed by `term_id`.
    var sessions: [String: TerminalSession] = [:]
    /// Terminal ids in card order: restore order, then the order they were
    /// added. Prime falls to its first live entry.
    var sessionOrder: [String] = []
    /// The prime terminal card's id, or nil when no terminal is live.
    var primeTermID: String?

    /// Provenance: doc path → the `term_id` that opened it (from `DocEntry`).
    var docOwner: [String: String] = [:]

    /// True once this board's first restore has been applied. Per-board because
    /// the daemon sends a restore for the active board on connect and again on
    /// every `board_switch` — each board latches independently.
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

    /// The prime terminal's view (the one that receives keyboard input).
    var primeTerminalView: TerminalView? { primeSession?.view }

    /// The prime terminal's board card (the focused terminal), or nil.
    var primeTermCard: CardView? {
        guard let id = primeTermID else { return nil }
        return view.card(.term(id))
    }

    /// Whether the prime terminal is backed by a live pty — drives doc-card
    /// quieting.
    var hasLivePrime: Bool { primeSession?.live == true }

    /// The terminals in card order, as the prime rule sees them.
    var primeTerms: [TermPrime.Term] {
        sessionOrder.compactMap { id in
            sessions[id].map { TermPrime.Term(termID: id, isLive: $0.live) }
        }
    }

    /// The terminals in card order, as a restore's `live_terms` is reconciled
    /// against them.
    var reconnectTerms: [ReconnectRestore.Term] {
        sessionOrder.compactMap { id in
            guard let session = sessions[id] else { return nil }
            let pty: ReconnectRestore.Pty = session.needsSpawn ? .unspawned : session.live ? .live : .dead
            return ReconnectRestore.Term(termID: id, pty: pty)
        }
    }

    /// Live terminals other than `termID` — what decides whether an exit or a
    /// close leaves the board without a terminal.
    func otherLiveTerminals(than termID: String) -> Int {
        sessions.values.filter { $0.termID != termID && $0.live }.count
    }

    /// Hands prime to the first live terminal when the prime is gone or dead.
    func reassignPrime() {
        primeTermID = TermPrime.reassign(primeTerms, prime: primeTermID)
    }

    /// Doc paths currently on this board.
    var boardDocPaths: [String] {
        view.cards.keys.compactMap {
            if case .doc(let path) = $0 { return path }
            return nil
        }
    }
}
