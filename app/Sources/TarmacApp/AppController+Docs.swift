import AppKit
import TarmacKit
import TarmacTerm

extension AppController {
    /// `.doc_opened`: route the doc to the board owning its caller term (the
    /// `tarmac open` that produced it ran with that term's `TARMAC_TERM_ID`),
    /// falling back to the active board for a user open / unknown term. The doc's
    /// state lands in THAT board's store and a `tarmac open` lands a fresh card on
    /// THAT board — so an open from a backgrounded board's shell never lands a
    /// card on the active board (crit S4); read-on-open only applies to the
    /// active board (visible cards are the active board's).
    func handleDocOpened(_ doc: RestoreDoc) {
        let board = doc.termID.flatMap { ownerBoard(ofTerm: $0) } ?? activeBoard
        let wasOnBoard = board.view.card(.doc(doc.path)) != nil
        board.store.applyDocOpened(doc)
        if let termID = doc.termID { board.docOwner[doc.path] = termID }
        // A doc arriving via `tarmac open` lands a FRESH card right of its caller
        // term card (first free slot). A user open keeps prior behavior (no card).
        if doc.via == "cli", !wasOnBoard {
            landFreshCard(path: doc.path, on: board)
            persistLayout(for: board)
            // The store's change callback ran before the card existed, and the
            // doc count and cold-start hint follow the cards.
            if board === activeBoard { refreshStrips() }
        }
        // Read-on-open applies only when the doc is already on the ACTIVE board
        // (a brand-new fresh card keeps its unread/fresh ring until touched).
        guard board === activeBoard else { return }
        if wasOnBoard {
            board.store.markRead(doc.path)
            client.docRead(path: doc.path)
            clearFreshIfRead(doc.path)
        }
    }

    /// Adds (or replaces) a doc card, renders its content, and seeds gravity:
    /// ownerTermID from the doc's provenance + the attached flag (owner chip
    /// shown while attached). `fresh` gives the just-spawned ring + `✚ now`.
    @discardableResult
    func landDocCard(path: String, frame: CardFrame, attached: Bool, fresh: Bool, on board: Board? = nil) -> CardView {
        let b = board ?? activeBoard
        let card = b.view.addCard(id: .doc(path), worldFrame: frame)
        if let doc = b.store.doc(for: path) { card.apply(doc: doc) }
        card.ownerTermID = ownerCardID(for: path, on: b)
        card.attached = attached && card.ownerTermID != nil
        if fresh { card.setFresh(true) }
        card.setOwnerChip(ownerChipLabel(for: card, on: b))
        card.renderDoc(markdown: readMarkdown(path))
        b.view.recomputeEdges()
        // A doc card is quiet while a terminal is prime (crib §4).
        if b.hasLivePrime { card.setQuiet(true) }
        return card
    }

    /// The board CardID of a doc's provenance owner term card, when resolvable
    /// (Phase 5b): the doc binds to *its* terminal — the `term_id` that opened it
    /// — not "the" terminal. Returns nil (doc stays loose) when that terminal no
    /// longer exists (e.g. a genuinely-orphaned owner after a restart remap).
    private func ownerCardID(for path: String, on board: Board? = nil) -> CardID? {
        let b = board ?? activeBoard
        // The pure resolution (owner recorded + still one of this board's live
        // terminals) lives in TarmacKit; map it to a card after confirming the
        // term card exists on the board.
        guard let tid = DocRouting.resolveOwner(
            path: path,
            owners: b.docOwner,
            liveTermIDs: Set(b.sessions.keys)
        ), b.view.card(.term(tid)) != nil else {
            return nil
        }
        return .term(tid)
    }

    /// `← <termname>` chip text for an attached doc card, else nil — the label of
    /// the doc's owner terminal (Phase 5b: its own terminal, not "the" terminal).
    func ownerChipLabel(for card: CardView, on board: Board? = nil) -> String? {
        let b = board ?? activeBoard
        guard card.attached, case .term(let ownerID)? = card.ownerTermID else { return nil }
        let label = b.sessions[ownerID]?.label ?? ""
        return label.isEmpty ? nil : label
    }

    /// Re-resolves any still-unbound doc-card owners and refreshes the owner chips
    /// with the now-known term label. `landDocCard` already resolves owners at
    /// restore (the term card exists from init, so `ownerCardID` resolves), making
    /// this mostly a chip refresh; it also covers the ordering where a card was
    /// restored attached before its owner was resolvable. A detached card stays
    /// detached. Called from maybeSpawn.
    func rebindOwners() {
        for path in boardDocPaths {
            guard let card = activeBoard.view.card(.doc(path)) else { continue }
            if card.ownerTermID == nil, card.attached {
                card.ownerTermID = ownerCardID(for: path)
            }
            card.setOwnerChip(ownerChipLabel(for: card))
        }
        activeBoard.view.recomputeEdges()
    }

    // MARK: - Fresh card landing (crib §5)

    /// Lands a fresh doc card to the right of its CALLER term card (the terminal
    /// that ran `tarmac open`, not necessarily the prime one) via a first-free-
    /// slot search; gives it the fresh ring + `✚ now` meta.
    private func landFreshCard(path: String, on board: Board? = nil) {
        let b = board ?? activeBoard
        let caller = ownerCardID(for: path, on: b).flatMap { b.view.card($0) }
        let frame = firstFreeSlot(near: caller, on: b)
        landDocCard(path: path, frame: frame, attached: true, fresh: true, on: b)
    }

    /// First-free-slot search (crib §5): start at the anchor term card's right
    /// edge + ~gapX (the caller terminal, or the prime terminal when no anchor),
    /// find a docW×docH world rect not overlapping existing cards, scanning right
    /// then down.
    private func firstFreeSlot(near anchorCard: CardView? = nil, on board: Board? = nil) -> CardFrame {
        let b = board ?? activeBoard
        let term = (anchorCard ?? b.primeTermCard)?.worldFrame ?? Place.termFrame
        let startX = term.x + term.w + Place.gapX
        let startY = term.y
        let stepX = Place.docW + Place.gapX
        let stepY = Place.docH + Place.gapY
        let existing = b.view.cards.values.map(\.worldFrame.rect)
        let topZ = (b.view.cards.values.map(\.worldFrame.z).max() ?? 0) + 1
        for row in 0..<64 {
            for col in 0..<64 {
                let candidate = CGRect(
                    x: startX + CGFloat(col) * stepX,
                    y: startY + CGFloat(row) * stepY,
                    width: Place.docW,
                    height: Place.docH
                )
                let clash = existing.contains { $0.intersects(candidate.insetBy(dx: -8, dy: -8)) }
                if !clash {
                    return CardFrame(rect: candidate, z: topZ)
                }
            }
        }
        // Fallback: stack a little past the term card.
        return CardFrame(x: startX, y: startY, w: Place.docW, h: Place.docH, z: topZ)
    }

    /// Marking a doc read clears its fresh ring (crib §5).
    private func clearFreshIfRead(_ path: String) {
        guard let card = activeBoard.view.card(.doc(path)), card.fresh else { return }
        card.setFresh(false)
    }

    /// Closes a doc card: removes it from the board and persists. The doc stays
    /// in `DocStore`. The single teardown choke point for the header ✕ and ⌘W;
    /// clearing focus here keeps `focusedCardID` from ever pointing at a removed
    /// card (a stale focus would desync scroll routing).
    func closeDocCard(_ path: String) {
        if focusedCardID == .doc(path) { defocus() }
        activeBoard.view.removeCard(id: .doc(path))
        persistLayout()
        refreshStrips()
    }

    func isOnBoard(_ path: String) -> Bool {
        activeBoard.view.card(.doc(path)) != nil
    }

    // MARK: - Docs

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
    /// updates the status-bar counts + cold-start hint.
    func refreshStrips() {
        for path in boardDocPaths {
            guard let card = activeBoard.view.card(.doc(path)) else { continue }
            if let doc = store.doc(for: path) { card.apply(doc: doc) }
            card.setOwnerChip(ownerChipLabel(for: card))
        }
        rootView.statusBar.setCounts(board: boardDocPaths.count)
        // M3: show which board is active + how many exist (a switch is otherwise
        // invisible until P4's titlebar chip / ⌘K switcher).
        let count = max(boardMetas.count, boards.count)
        rootView.statusBar.setBoard(activeBoard.name ?? activeBoardID, count: count)
        updateWindowTitle()
        updateSessionLiveness()
        rootView.coldStartHint.isHidden = !boardDocPaths.isEmpty
    }

    /// `tarmac open · HH:MM` edge label (crib §8): HH:MM from the doc's
    /// lastOpenedMs in local time. nil when the doc/time is unknown.
    func edgeLabel(for id: CardID) -> String? {
        guard case .doc(let path) = id, let doc = store.doc(for: path), let ms = doc.lastOpenedMs else {
            return nil
        }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return "tarmac open · \(Self.hhmmFormatter.string(from: date))"
    }

    func readMarkdown(_ path: String) -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return "could not read `\(path)`\n\n```\n\(error.localizedDescription)\n```\n"
        }
    }
}
