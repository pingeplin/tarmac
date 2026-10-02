import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    // MARK: - Opening

    /// `doc_opened`: the doc goes to the board that owns the terminal which
    /// opened it, or to the active board when it names none. Every open lands
    /// a card; one already on that board is refreshed where it is
    /// (`DocLanding`).
    func handleDocOpened(_ doc: RestoreDoc) {
        let board = doc.termID.flatMap { ownerBoard(ofTerm: $0) } ?? activeBoard
        let path = doc.path
        let existing = board.view.card(.doc(path))
        board.store.applyDocOpened(doc)
        board.docOwner[path] = DocLanding.owner(opened: doc.termID, current: board.docOwner[path])

        switch DocLanding.decide(
            onBoard: existing != nil, via: doc.via, termID: doc.termID, wasFresh: existing?.fresh ?? false
        ) {
        case .land(let fresh, let attached):
            landDocCard(path: path, frame: freeSlot(for: path, on: board), attached: attached, fresh: fresh, on: board)
        case .refresh(let fresh):
            guard let card = existing else { break }
            card.setFresh(fresh)
            bind(card, path: path, on: board)
            card.docBody?.refresh(lastChangedMs: board.store.doc(for: path)?.lastChangedMs)
            board.view.recomputeEdges()
        }
        persistLayout(for: board)
        if board === activeBoard { refreshStrips() }
        refreshSwitcherIfOpen()
    }

    /// Puts a doc card on `board` and shows the doc in it.
    @discardableResult
    func landDocCard(path: String, frame: CardFrame, attached: Bool, fresh: Bool, on board: Board) -> CardView {
        let card = board.view.addCard(id: .doc(path), worldFrame: frame)
        card.attached = attached
        card.setFresh(fresh)
        bind(card, path: path, on: board)
        wireBorrow(card)
        card.docBody?.refresh(lastChangedMs: board.store.doc(for: path)?.lastChangedMs)
        board.view.recomputeEdges()
        return card
    }

    /// Gives a doc card what the registry knows about it: its header, and the
    /// terminal that opened it.
    private func bind(_ card: CardView, path: String, on board: Board) {
        if let doc = board.store.doc(for: path) { card.apply(doc: doc) }
        card.ownerTermID = board.docOwner[path].map(CardID.term)
        card.setOwnerChip(ownerChipLabel(for: card, on: board))
    }

    /// The first free slot beside the doc's owner terminal (`Placement`), on
    /// top of every card on the board.
    private func freeSlot(for path: String, on board: Board) -> CardFrame {
        let owner = board.docOwner[path].flatMap { board.view.card(.term($0)) }
        let anchor = DocLanding.anchor(owner: owner?.worldFrame.rect, prime: board.primeTermCard?.worldFrame.rect)
        let cards = board.view.cards.values
        return CardFrame(
            rect: Placement.firstFreeSlot(owner: anchor, existing: cards.map(\.worldFrame.rect)),
            z: ZOrder.raised(above: cards.map(\.worldFrame.z))
        )
    }

    // MARK: - Owner chip

    /// The `← <terminal>` chip of a doc card: its owner terminal's label while
    /// that terminal is on the board and running. Whether the doc still
    /// follows the terminal has no say in it.
    func ownerChipLabel(for card: CardView, on board: Board) -> String? {
        guard case .term(let ownerID)? = card.ownerTermID else { return nil }
        return OwnerChip.name(ownerTermID: ownerID) { termID in
            guard let session = board.sessions[termID], session.live,
                  board.view.card(.term(termID))?.dead == false
            else { return nil }
            return session.label
        }
    }

    /// A terminal on `board` was renamed, exited or went away.
    func refreshOwnerChips(on board: Board) {
        for card in board.view.cards.values {
            guard case .doc = card.id else { continue }
            card.setOwnerChip(ownerChipLabel(for: card, on: board))
        }
    }

    // MARK: - Change, refresh, close

    /// `file_event`: the watcher is global, so every board that knows the doc
    /// takes the change time and shows the doc again.
    func handleFileEvent(path: String, mtimeMs: UInt64) {
        for board in boards.values where board.store.doc(for: path) != nil {
            board.store.applyFileEvent(path: path, mtimeMs: mtimeMs)
            guard let card = board.view.card(.doc(path)) else { continue }
            if let doc = board.store.doc(for: path) { card.apply(doc: doc) }
            card.docBody?.refresh(lastChangedMs: mtimeMs)
        }
    }

    /// The header `↻`. Nothing changes here: the daemon stats the file and its
    /// `file_event` is what shows the doc again.
    func refreshDocFromDisk(_ path: String) {
        client.docRefresh(path: path)
    }

    /// The header `✕` and ⌘W on a doc: the card, its registry entry and a
    /// borrow on it go, and the daemon forgets and unwatches the doc.
    func closeDocCard(_ path: String) {
        let id = CardID.doc(path)
        borrow.closed(id)
        if focusedCardID == id { defocus() }
        activeBoard.view.removeCard(id: id)
        activeBoard.docOwner[path] = nil
        activeBoard.store.remove(path)
        client.docClose(path: path)
        persistLayout(for: activeBoard)
        refreshStrips()
        refreshSwitcherIfOpen()
    }

    // MARK: - Chrome

    /// Wires a board's doc store to refresh the chrome on change — but only while
    /// that board is active (a backgrounded board's store can mutate via a
    /// cross-board file event, which must not refresh the active chrome).
    func wireStore(_ board: Board) {
        let bid = board.boardID
        board.store.onChange = { [weak self] in self?.storeChanged(onBoardID: bid) }
    }

    private func storeChanged(onBoardID bid: String) {
        if bid == activeBoardID { refreshStrips() }
    }

    /// Syncs on-board card headers (incl. owner chips) with the registry, and
    /// the window title and the status bar's link word with the app.
    func refreshStrips() {
        for path in activeBoard.boardDocPaths {
            guard let card = activeBoard.view.card(.doc(path)) else { continue }
            if let doc = store.doc(for: path) { card.apply(doc: doc) }
        }
        refreshOwnerChips(on: activeBoard)
        updateWindowTitle()
        updateSessionLiveness()
    }
}
