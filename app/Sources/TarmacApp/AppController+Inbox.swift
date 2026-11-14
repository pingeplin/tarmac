import AppKit
import TarmacKit

extension AppController {
    // MARK: - The store (2611.0013)

    /// The board a term-keyed frame names; an older daemon names none, and
    /// the app's own index stands in.
    func inboxBoard(_ boardID: String?, termID: String) -> String? {
        boardID ?? ownerBoard(ofTerm: termID)?.boardID
    }

    var wallClockMs: UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// The user touched the terminal: typed into it, or pressed its card.
    func touchInbox(termID: String) {
        let before = inbox
        inbox.touch(termID: termID)
        if inbox != before { inboxChanged() }
    }

    /// After each change of the store: the exit pills, the button, an open
    /// panel and an open switcher follow it.
    func inboxChanged() {
        for board in boards.values {
            var changed = false
            for termID in board.sessionOrder {
                guard let card = board.view.card(.term(termID)) else { continue }
                let unread = inbox.exitUnread(termID: termID)
                guard card.exitUnread != unread else { continue }
                card.exitUnread = unread
                changed = true
            }
            if changed { board.view.signalsChanged() }
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
        let now = wallClockMs
        let home = NSHomeDirectory()
        rootView.inboxPanel.render(InboxPanelView.Model(
            unread: inbox.unreadCount,
            filter: inboxState.filter,
            rows: items.map { item in
                InboxPanelView.Row(
                    id: item.id, kind: item.kind, title: InboxCopy.title(item), quote: InboxCopy.quote(item),
                    place: InboxCopy.place(
                        item, boardName: boardMetas.first { $0.boardID == item.boardID }?.name,
                        cardLabel: boards[item.boardID]?.sessions[item.termID]?.label, home: home
                    ),
                    age: InboxCopy.age(item, nowMs: now), read: item.read
                )
            },
            selected: inboxState.selected
        ))
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
            inbox.dismiss(id)
            inboxChanged()
        }
        return true
    }

    func setInboxFilter(_ filter: Inbox.Filter) {
        inboxState = InboxKeys.State(filter: filter, selected: nil)
        renderInbox()
    }

    func clearReadInbox() {
        inbox.clearRead(inboxState.filter)
        inboxChanged()
    }

    // MARK: - The jump

    /// ↵ or a click on a row: at most one board switch, then one flight. The
    /// keys go to the card it lands on; a jump to a card that went drops its
    /// row and gives the keys back.
    func jump(to id: Inbox.ItemID) {
        guard let item = inbox.items(.all).first(where: { $0.id == id }) else { return }
        let owner = rootView.inboxPanel.keysOwner
        closeInbox(returnKeys: false)
        preFlightViewport = nil
        switch InboxJump.plan(item, activeBoardID: activeBoardID) {
        case .fly:
            if !land(id, on: activeBoard) { giveKeysBack(to: owner) }
        case .switchThenFly(let boardID, _):
            pendingJump = (boardID, id)
            performSwitch(to: boardID)
            guard activeBoardID != boardID else { return }
            pendingJump = nil
            inbox.dismiss(id)
            inboxChanged()
            giveKeysBack(to: owner)
        }
    }

    /// `finishArrive`'s part: lands a jump waiting for `board`; one for
    /// another board was overtaken by a later switch and is dropped. True
    /// when the landing placed the keys.
    func landPendingJump(on board: Board) -> Bool {
        guard let jump = pendingJump else { return false }
        pendingJump = nil
        guard jump.boardID == board.boardID else { return false }
        return land(jump.item, on: board)
    }

    /// On `board`, which is the active one: the item's card, or the fresh
    /// shell a first build put in its place.
    @discardableResult
    private func land(_ id: Inbox.ItemID, on board: Board) -> Bool {
        let target = inbox.target(termID: id.termID)
        let card = target.flatMap { board.view.card(.term($0)) }
        let landing = InboxJump.land(cardExists: card != nil, cardDead: card?.dead ?? false)
        guard let target, landing != .drop else { return drop(id) }
        switch landing {
        case .drop:
            return drop(id)
        case .prime:
            board.primeTermID = target
            updatePrimacy(on: board)
            if let view = board.sessions[target]?.view { window?.makeFirstResponder(view) }
        case .select:
            board.view.select(.term(target))
            window?.makeFirstResponder(rootView.board)
        }
        board.view.fly(to: .term(target))
        inbox.touch(termID: id.termID)
        inbox.touch(termID: target)
        clearBell(termID: target)
        inboxChanged()
        return true
    }

    private func drop(_ id: Inbox.ItemID) -> Bool {
        inbox.dismiss(id)
        inboxChanged()
        return false
    }

    private func giveKeysBack(to owner: NSResponder?) {
        if let view = owner as? NSView, view.window === window { window?.makeFirstResponder(view) }
    }
}
