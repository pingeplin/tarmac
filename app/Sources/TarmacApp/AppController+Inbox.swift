import AppKit
import TarmacKit

extension AppController {
    // MARK: - The store (2611.0013)

    /// Feeds the store from a daemon frame, before any handler looks for a
    /// card (D4): a frame of a board not built yet still makes its row. A
    /// frame names its board; an older daemon's does not, and the app's own
    /// index stands in. An exit's process is read before `holdOpen` drops it.
    func feedInbox(_ message: Message) {
        switch message {
        case .termReport:
            guard let frame = TermReport.frame(message) else { return }
            if let cwd = frame.cwd { anySession(frame.termID)?.session.lastCwd = cwd }
            let fallback = ownerBoard(ofTerm: frame.termID)?.boardID
            if inbox.apply(frame, fallbackBoard: fallback) { inboxChanged([frame.termID]) }
        case .bell(let termID, let boardID):
            guard let board = boardID ?? ownerBoard(ofTerm: termID)?.boardID else { return }
            let s = anySession(termID)?.session
            let changed = inbox.bell(
                termID: termID, boardID: board, proc: s?.procName, cwd: s?.lastCwd, nowMs: WallClock.nowMs
            )
            if changed { inboxChanged([termID]) }
        case .exit(let termID, let code, let boardID):
            guard let board = boardID ?? ownerBoard(ofTerm: termID)?.boardID else { return }
            let s = anySession(termID)?.session
            let changed = inbox.exit(
                termID: termID, boardID: board, code: code, proc: s?.procName, cwd: s?.lastCwd, nowMs: WallClock.nowMs
            )
            if changed { inboxChanged([termID]) }
        case .boardList(let metas, _):
            // A board never built here has no `Board` to remove: its rows go
            // with the list.
            if inbox.keepBoards(Set(metas.map(\.boardID))) { inboxChanged() }
        default:
            break
        }
    }

    /// The user touched the terminal (`clearBell`).
    func touchInbox(termID: String) {
        if inbox.touch(termID: termID) { inboxChanged([termID]) }
    }

    /// After a change of the store: the pills of the boards that hold
    /// `terms` (every board for nil), the button, an open panel and an open
    /// switcher follow it.
    func inboxChanged(_ terms: Set<String>? = nil) {
        for board in boards.values where terms.map({ !$0.isDisjoint(with: board.sessionOrder) }) ?? true {
            board.view.signalsChanged()
        }
        inboxButton?.setTitle(InboxBadge.text(unread: inbox.unreadCount))
        if inboxOpen { renderInbox() }
        refreshSwitcherIfOpen()
    }

    // MARK: - The title-bar button

    /// The button sits in the title bar, which follows the system's
    /// appearance, not the theme. In full screen it shows with the title bar.
    func installInboxButton() {
        guard let window, inboxButton == nil else { return }
        let button = InboxTitlebarButton(title: InboxBadge.text(unread: inbox.unreadCount))
        button.onClick = { [weak self] in self?.toggleInbox() }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = button.container
        window.addTitlebarAccessoryViewController(accessory)
        inboxButton = button
    }

    // MARK: - The panel

    func toggleInbox() {
        if inboxOpen { closeInbox() } else { openInbox() }
    }

    /// Opens on the filter last used in this run, its top row selected. It
    /// holds first responder while it is up, as the switcher does, so the
    /// menu's Paste never reaches the terminal behind it. Opening marks
    /// nothing read.
    func openInbox() {
        guard !inboxOpen else { return }
        closeSwitcher()
        inboxOpen = true
        inboxState.selected = nil
        inboxState.focus = .list
        inboxRows = []
        rootView.setInboxVisible(true)
        rootView.layoutSubtreeIfNeeded()
        renderInbox()
        rootView.inboxPanel.takeKeys()
        let tick = Timer(timeInterval: ReportChip.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderInbox() }
        }
        RunLoop.main.add(tick, forMode: .common)
        inboxTick = tick
    }

    /// `returnKeys: false` leaves the keys with the board, for a jump that
    /// gives them to its target.
    func closeInbox(returnKeys: Bool = true) {
        guard inboxOpen else { return }
        inboxOpen = false
        inboxTick?.invalidate()
        inboxTick = nil
        // Before the view is hidden: hiding the first responder hands the keys
        // to the window, and there would be nothing left to give back.
        if returnKeys {
            rootView.inboxPanel.returnKeys(fallback: rootView.board)
        } else {
            rootView.inboxPanel.keysOwner = nil
            window?.makeFirstResponder(rootView.board)
        }
        rootView.setInboxVisible(false)
    }

    func renderInbox() {
        let items = inbox.items(inboxState.filter)
        let rows = items.map(\.id)
        inboxState.selected = InboxKeys.reselect(inboxState.selected, oldRows: inboxRows, newRows: rows)
        inboxRows = rows
        let now = WallClock.nowMs
        let home = NSHomeDirectory()
        let rowsShown = items.map { item in
            InboxCopy.row(
                item, boardName: boardMetas.first { $0.boardID == item.boardID }?.name,
                cardLabel: boards[item.boardID]?.sessions[item.termID]?.label, home: home, nowMs: now
            )
        }
        let selected = items.firstIndex { $0.id == inboxState.selected }
        rootView.inboxPanel.render(InboxPanelView.Model(
            unread: inbox.unreadCount,
            filter: inboxState.filter,
            rows: rowsShown,
            selected: inboxState.selected,
            preview: selected.map { InboxCopy.preview(items[$0], place: rowsShown[$0].place, nowMs: now) },
            gripFocused: inboxState.focus == .grip
        ))
    }

    /// A click on a row (spec 2611.0018 D5): it selects and previews; a
    /// double-click on the selected row flies.
    func clickInbox(_ id: Inbox.ItemID, count: Int) {
        let (state, effect) = InboxKeys.click(id, count: count, state: inboxState)
        if case .jump(let id) = effect { return jump(to: id) }
        inboxState = state
        renderInbox()
    }

    func focusInboxGrip() {
        inboxState.focus = .grip
        renderInbox()
    }

    /// A key the open panel owns (`InboxKeys`). False leaves it for the menu.
    func handleInboxKey(_ press: KeyPress) -> Bool {
        let (state, effect) = InboxKeys.handle(press, state: inboxState, rows: inboxRows)
        switch effect {
        case .leaveForMenu:
            return false
        case .none:
            inboxState = state
            renderInbox()
        case .close:
            closeInbox()
        case .jump(let id):
            jump(to: id)
        case .remove(let id):
            if inbox.dismiss(id) { inboxChanged([id.termID]) }
        case .resizePane(let steps):
            rootView.inboxPanel.stepPane(steps)
        }
        return true
    }

    func setInboxFilter(_ filter: Inbox.Filter) {
        inboxState = InboxKeys.State(filter: filter, selected: nil)
        renderInbox()
    }

    func clearReadInbox() {
        if inbox.clearRead(inboxState.filter) { inboxChanged() }
    }

    // MARK: - The jump

    /// ↵, a double-click on a row or a `go ↵`: at most one board switch, then
    /// one flight. The keys go to the card it lands on; a jump to a card that
    /// went removes its row and gives the keys back.
    func jump(to id: Inbox.ItemID) {
        guard let item = inbox.item(id) else { return }
        let owner = rootView.inboxPanel.keysOwner
        closeInbox(returnKeys: false)
        preFlightViewport = nil
        if let boardID = InboxJump.switchTarget(item, activeBoardID: activeBoardID) {
            pendingJump = (boardID, id)
            performSwitch(to: boardID)
            // `finishArrive` lands it; a refused switch drops it here.
            if activeBoardID == boardID { return }
            pendingJump = nil
        } else if let home = land(id, on: activeBoard) {
            window?.makeFirstResponder(home)
            return
        }
        drop(id)
        if let view = owner as? NSView, view.window === window { window?.makeFirstResponder(view) }
    }

    /// `finishArrive`'s part: lands a jump waiting for `board`, and returns
    /// the view that takes the keys; one for another board was overtaken by
    /// a later switch.
    func landPendingJump(on board: Board) -> NSView? {
        guard let jump = pendingJump else { return nil }
        pendingJump = nil
        guard jump.boardID == board.boardID else { return nil }
        if let home = land(jump.item, on: board) { return home }
        drop(jump.item)
        return nil
    }

    /// A click on an edge pill: the jump of an inbox row to the card the pill
    /// stands for, which is on the active board, so it switches nowhere.
    func jump(toCard termID: String) {
        closeInbox(returnKeys: false)
        preFlightViewport = nil
        if let home = land(card: termID, on: activeBoard) { window?.makeFirstResponder(home) }
    }

    /// On `board`, which is the active one: the item's card, or the fresh
    /// shell a first build put in its place.
    private func land(_ id: Inbox.ItemID, on board: Board) -> NSView? {
        guard let target = inbox.target(termID: id.termID), let home = land(card: target, on: board) else { return nil }
        touchInbox(termID: id.termID)
        return home
    }

    /// Flies to `termID`'s card and primes or selects it (`InboxJump.land`).
    /// Returns the view that takes the keys, which the caller hands them to;
    /// nil when there is no card.
    private func land(card termID: String, on board: Board) -> NSView? {
        let card = board.view.card(.term(termID))
        let view = board.sessions[termID]?.view
        let home: NSView
        switch InboxJump.land(cardExists: card != nil, cardDead: card?.dead ?? false) {
        case .drop:
            return nil
        case .prime:
            guard let view else { return nil }
            board.primeTermID = termID
            updatePrimacy(on: board)
            home = view
        case .select:
            // A dead card holds the keys, as a click on it does, so that
            // Return reaches its reopen offer (2611.0011, D10).
            board.view.select(.term(termID))
            home = view ?? rootView.board
        }
        board.view.fly(to: .term(termID))
        clearBell(termID: termID)
        return home
    }

    private func drop(_ id: Inbox.ItemID) {
        if inbox.remove(id) { inboxChanged([id.termID]) }
    }
}
