import AppKit
import SwiftTerm
import TarmacKit

/// Bridges SwiftTerm's non-isolated TerminalViewDelegate onto the MainActor
/// controller (callbacks arrive on the main thread in practice).
final class TermDelegateBridge: NSObject, TerminalViewDelegate {
    weak nonisolated(unsafe) var controller: AppController?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let controller else { return }
        MainActor.assumeIsolated { controller.terminalSizeChanged(cols: newCols, rows: newRows) }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let controller else { return }
        let bytes = Data(data)
        MainActor.assumeIsolated { controller.terminalDidSend(bytes) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    // The daemon is the authoritative BEL source (it reads the pty stream);
    // ignore the view-side echo.
    func bell(source: TerminalView) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
final class AppController {
    let client: DaemonClient
    let terminalView: TerminalView
    let rootView: RootView
    private weak var window: NSWindow?
    private let termDelegate = TermDelegateBridge()

    private var connected = false
    private var viewReady = false
    private var currentTermID: String?
    private var lastSentCols = 0
    private var lastSentRows = 0
    private var lastSpawnAt: Date?
    private var rapidExitCount = 0

    private let store = DocStore()
    /// Set just before a doc_opened upsert so the 0→1 transition (and only it)
    /// plays the dock birth slide; restore populates without animation.
    private var dockBirthPending = false
    private var escMonitor: Any?

    // MARK: - Board placement rule (crib §4/§5)
    //
    // World-frame defaults for fresh placement and the M1→v4 restore scatter.
    // Sizes follow the crib's illustrative B2 frames (term 470×330, doc 392×310);
    // gaps are the illustrative ~86px horizontal / 32px vertical.
    private enum Place {
        static let termFrame = CardFrame(x: 80, y: 80, w: 470, h: 330, z: 0)
        static let docW: CGFloat = 392
        static let docH: CGFloat = 310
        static let gapX: CGFloat = 86
        static let gapY: CGFloat = 40
        static let docColumns = 2
    }

    init(window: NSWindow, rootView: RootView) {
        self.window = window
        self.rootView = rootView
        self.client = DaemonClient()

        terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminalView.font = Theme.mono(12)
        terminalView.nativeBackgroundColor = Theme.termBg
        terminalView.nativeForegroundColor = Theme.termFg
        terminalView.caretColor = Theme.text
        terminalView.optionAsMetaKey = true
        termDelegate.controller = self
        terminalView.terminalDelegate = termDelegate
        // The terminal is a board card like any other (crib §4); it lands near
        // the world origin and is reflowed on resize-commit.
        rootView.attachTerminal(terminalView, worldFrame: Place.termFrame)

        store.onChange = { [weak self] in self?.docsChanged() }
        store.onFileChange = { [weak self] path in self?.rootView.dock.pulse(path) }
        rootView.dock.onPeek = { [weak self] path in self?.openPeek(path) }
        rootView.dock.onToggleIndex = { [weak self] in self?.toggleIndex() }
        rootView.index.onPeek = { [weak self] path in self?.openPeek(path) }
        rootView.index.onToggleIndex = { [weak self] in self?.toggleIndex() }
        rootView.peek.onPin = { [weak self] in self?.togglePinPeeked() }
        rootView.peek.onClose = { [weak self] in self?.hidePeek() }
        // A committed move/resize/zoom/pan on the board persists the full layout
        // snapshot (card world frames + board viewport); last-writer-wins.
        // TODO(perf): pan fires onLayoutChanged per scroll event — cheap LWW for
        // now; debounce/coalesce the layout send if pan persistence gets chatty.
        rootView.board.onLayoutChanged = { [weak self] _ in self?.persistLayout() }
    }

    func start() {
        client.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.handle(message) }
        }
        client.onDisconnect = { [weak self] reason in
            MainActor.assumeIsolated { self?.handleDisconnect(reason) }
        }

        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEsc = event.keyCode == 53
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                guard let self, isEsc else { return false }
                // An active board drag/resize swallows esc ahead of peek/toast
                // dismissal (crib §5 DECISION; was desk.cancelDrag()).
                if self.rootView.board.cancelDrag() {
                    return true
                }
                if self.rootView.peekVisible {
                    self.hidePeek()
                    return true
                }
                if self.rootView.toasts.hasToasts {
                    self.rootView.toasts.clearAll()
                    return true
                }
                return false
            }
            return swallowed ? nil : event
        }

        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try client.connect()
            } catch {
                let detail = "\(error)"
                FileHandle.standardError.write(Data("tarmac: \(detail)\n".utf8))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in self?.showConnectFailure(detail) }
                }
            }
        }

        // Layout has happened by the next runloop turn; sizeChanged also flips
        // this, whichever lands first.
        DispatchQueue.main.async { [weak self] in
            self?.viewReady = true
            self?.maybeSpawn()
        }
    }

    // MARK: - Daemon messages

    private func handle(_ message: Message) {
        switch message {
        case .helloOK:
            connected = true
            maybeSpawn()
        case .restore(let docs, let tiles, let board):
            store.applyRestore(docs)
            applyRestoredLayout(tiles: tiles, board: board)
            refreshStrips()
        case .output(let termID, let bytes):
            guard termID == currentTermID else { return }
            terminalView.feed(byteArray: [UInt8](bytes)[...])
        case .exit(let termID, let code):
            handleExit(termID: termID, code: code)
        case .docOpened(let doc):
            let firstDoc = store.isEmpty
            dockBirthPending = firstDoc
            store.applyDocOpened(doc)
            // TODO(Phase 3): replace this toast with a `fresh` card landing right
            // of the caller terminal card (gravity/shelf). docOpened may still
            // toast for now per the Phase 2c scope.
            if doc.via == "cli" {
                let peekAction: () -> Void = { [weak self, path = doc.path] in self?.openPeek(path) }
                let peekChip = (firstDoc ? "⌘P peek" : "⏎ peek", peekAction)
                rootView.toasts.show(
                    icon: "✚",
                    title: firstDoc ? "first doc · \(doc.displayPath)" : "tarmac open \(doc.displayPath)",
                    body: firstDoc ? "opened via tarmac open" : nil,
                    chips: [peekChip, ("esc", nil)]
                )
            }
            if (rootView.peekVisible && peekPath == doc.path) || isOnBoard(doc.path) {
                // The doc is on screen: mark read immediately (crib-state §2.1).
                store.markRead(doc.path)
                client.docRead(path: doc.path)
                if rootView.peekVisible && peekPath == doc.path {
                    refreshPeek(doc.path)
                }
            }
        case .fileEvent(let path, let mtimeMs):
            store.applyFileEvent(path: path, mtimeMs: mtimeMs)
            if isOnBoard(path) {
                rootView.board.card(.doc(path))?.renderDoc(markdown: readMarkdown(path))
            }
            if rootView.peekVisible && peekPath == path {
                refreshPeek(path)
            }
        case .err(let msg):
            FileHandle.standardError.write(Data("tarmacd err: \(msg)\n".utf8))
        case .unknown(let type):
            FileHandle.standardError.write(Data("tarmac: ignoring unknown message type \"\(type)\"\n".utf8))
        default:
            break
        }
    }

    private func handleDisconnect(_ reason: String) {
        connected = false
        currentTermID = nil
        feedNotice("lost connection to tarmacd — \(reason)")
        rootView.toasts.show(title: "tarmacd connection lost", body: reason)
    }

    private func showConnectFailure(_ detail: String) {
        feedNotice(detail)
        rootView.toasts.show(title: "cannot reach tarmacd", body: "see terminal for details")
    }

    // MARK: - Terminal session

    func terminalSizeChanged(cols: Int, rows: Int) {
        viewReady = true
        maybeSpawn()
        guard let termID = currentTermID, cols > 0, rows > 0,
              cols != lastSentCols || rows != lastSentRows else { return }
        lastSentCols = cols
        lastSentRows = rows
        client.resize(termID: termID, cols: cols, rows: rows)
    }

    func terminalDidSend(_ bytes: Data) {
        guard let termID = currentTermID else { return }
        client.input(termID: termID, bytes: bytes)
    }

    private func maybeSpawn() {
        guard connected, viewReady, currentTermID == nil else { return }
        let term = terminalView.getTerminal()
        let cols = max(2, term.cols)
        let rows = max(2, term.rows)
        let termID = UUID().uuidString
        currentTermID = termID
        lastSentCols = cols
        lastSentRows = rows
        lastSpawnAt = Date()
        client.spawnTerm(termID: termID, cols: cols, rows: rows, cwd: NSHomeDirectory(), cmd: nil)
        // cmd nil ⇒ the daemon spawns $SHELL (else /bin/zsh); mirror that
        // resolution for the card label — a fact known at spawn time.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        rootView.board.card(.term)?.setTermLabel((shell as NSString).lastPathComponent)
    }

    private func handleExit(termID: String, code: Int?) {
        guard termID == currentTermID else { return }
        currentTermID = nil
        let label = code.map { "exit \($0)" } ?? "killed by signal"
        feedNotice("shell exited (\(label)) — restarting…")

        if let spawnedAt = lastSpawnAt, Date().timeIntervalSince(spawnedAt) < 1.0 {
            rapidExitCount += 1
        } else {
            rapidExitCount = 0
        }
        guard rapidExitCount < 3 else {
            feedNotice("shell keeps exiting immediately — auto-respawn stopped")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.connected, self.currentTermID == nil else { return }
                self.maybeSpawn()
            }
        }
    }

    private func feedNotice(_ text: String) {
        terminalView.feed(text: "\r\n\u{1b}[2m· \(text)\u{1b}[0m\r\n")
    }

    // MARK: - Board layout (restore + persistence)

    /// `restore.tiles[]` → board cards. Tiles WITH `x/y/w/h` are placed at their
    /// stored world frame; tiles WITHOUT geometry (M1 layouts) get a default
    /// scatter (see `scatterFrame`). The terminal card always survives. Unknown
    /// kinds and unregistered doc paths are skipped per the protocol receiver
    /// rules. The board viewport is applied when present, else the default.
    private func applyRestoredLayout(tiles: [LayoutTile], board: BoardViewport?) {
        // Tear down any doc cards from a prior restore; the term card is kept and
        // re-placed (its embedded SwiftTerm view stays attached). Snapshot the ids
        // first — removeCard mutates the board's `cards` dictionary.
        for id in Array(rootView.board.cards.keys) {
            if case .doc = id { rootView.board.removeCard(id: id) }
        }

        // Index docs by slot order so the scatter is deterministic (slot order →
        // world coords): slot 0 = terminal near origin, doc slots flow to its
        // right in a `docColumns`-wide grid.
        var docSlot = 0
        var migratedAny = false
        for tile in tiles {
            let stored = CardFrame(tile: tile)
            switch tile.kind {
            case "term":
                if stored == nil { migratedAny = true }
                rootView.board.setTerminal(terminalView, worldFrame: stored ?? Place.termFrame)
            case "doc":
                guard let path = tile.path, store.doc(for: path) != nil else { continue }
                if stored == nil { migratedAny = true }
                landDocCard(path: path, frame: stored ?? scatterFrame(docSlot: docSlot))
                docSlot += 1
            default:
                continue // unknown kind: skip (protocol receiver rule)
            }
        }

        if migratedAny {
            let origin = "\(Int(Place.termFrame.x)),\(Int(Place.termFrame.y))"
            let docSize = "\(Int(Place.docW))×\(Int(Place.docH))"
            let log = "tarmac: migrated M1 layout → default scatter "
                + "(term near origin at \(origin); doc cards \(docSize) in a "
                + "\(Place.docColumns)-col grid right of the terminal)\n"
            FileHandle.standardError.write(Data(log.utf8))
        }

        rootView.board.setViewport(board.map(Viewport.init) ?? .default)
    }

    /// Default scatter for a geometry-less (M1) doc tile at `docSlot` (0-based):
    /// doc cards flow left→right, top→bottom in a `docColumns`-wide grid placed
    /// to the right of the terminal card, gapX past its right edge.
    private func scatterFrame(docSlot: Int) -> CardFrame {
        let term = Place.termFrame
        let col = docSlot % Place.docColumns
        let row = docSlot / Place.docColumns
        let x = term.x + term.w + Place.gapX + CGFloat(col) * (Place.docW + Place.gapX)
        let y = term.y + CGFloat(row) * (Place.docH + Place.gapY)
        return CardFrame(x: x, y: y, w: Place.docW, h: Place.docH, z: docSlot + 1)
    }

    /// Adds (or replaces) a doc card on the board and renders its content.
    private func landDocCard(path: String, frame: CardFrame) {
        let card = rootView.board.addCard(id: .doc(path), worldFrame: frame)
        if let doc = store.doc(for: path) { card.apply(doc: doc) }
        card.renderDoc(markdown: readMarkdown(path))
    }

    /// Doc paths currently on the board.
    private var boardDocPaths: [String] {
        rootView.board.cards.keys.compactMap {
            if case .doc(let path) = $0 { return path }
            return nil
        }
    }

    private func isOnBoard(_ path: String) -> Bool {
        rootView.board.card(.doc(path)) != nil
    }

    /// Reports the full layout snapshot: every card's world frame (`x/y/w/h/z`)
    /// plus the board viewport `{zoom,cx,cy}` (docs/protocol.md `layout`;
    /// last-writer-wins). Fired on every committed board move/resize/zoom/pan.
    private func persistLayout() {
        var tiles: [LayoutTile] = []
        // Terminal slot first, then doc cards in a stable (path-sorted) order.
        if let term = rootView.board.card(.term) {
            tiles.append(layoutTile(kind: "term", path: nil, frame: term.worldFrame))
        }
        for path in boardDocPaths.sorted() {
            guard let card = rootView.board.card(.doc(path)) else { continue }
            tiles.append(layoutTile(kind: "doc", path: path, frame: card.worldFrame))
        }
        client.layout(
            dock: store.docs.map(\.path),
            tiles: tiles,
            board: rootView.board.viewport.wire
        )
    }

    private func layoutTile(kind: String, path: String?, frame: CardFrame) -> LayoutTile {
        LayoutTile(
            kind: kind,
            path: path,
            x: Double(frame.x),
            y: Double(frame.y),
            w: Double(frame.w),
            h: Double(frame.h),
            z: frame.z
        )
    }

    // MARK: - Docs / peek

    private var peekPath: String? { rootView.peek.currentPath }
    private var activeDocPath: String? { rootView.peekVisible ? rootView.peek.currentPath : nil }

    private func docsChanged() {
        let birth = dockBirthPending
        dockBirthPending = false
        if store.isEmpty {
            rootView.setLeftStrip(.none)
        } else if rootView.leftStrip == .none {
            rootView.setLeftStrip(.dock, birth: birth)
        }
        refreshStrips()
    }

    private func refreshStrips() {
        var dockActive = Set(boardDocPaths)
        if let peeked = activeDocPath {
            dockActive.insert(peeked)
        }
        rootView.dock.update(docs: store.docs, activePaths: dockActive)
        rootView.index.update(docs: store.docs, activePath: activeDocPath)
        // Keep on-board doc card headers in sync with the registry.
        for path in boardDocPaths {
            if let doc = store.doc(for: path) { rootView.board.card(.doc(path))?.apply(doc: doc) }
        }
    }

    /// ⌘P: peek (or re-target) the most-recent doc — never closes an open peek
    /// (crib-state §6 supersedes M0's toggle).
    func peekRecent() {
        guard let path = store.mostRecentPath else {
            NSSound.beep()
            return
        }
        openPeek(path)
    }

    /// ⌘E: dock 46px ↔ index 224px; no-op before the first doc exists.
    func toggleIndex() {
        switch rootView.leftStrip {
        case .none:
            return
        case .dock:
            rootView.setLeftStrip(.index)
        case .index:
            rootView.setLeftStrip(.dock)
        }
        // Focus rule: clicks on the strip never move focus off the terminal.
        window?.makeFirstResponder(terminalView)
    }

    func openPeek(_ path: String) {
        rootView.peek.present(path: path, doc: store.doc(for: path), markdown: readMarkdown(path))
        rootView.setPeekVisible(true)
        // Presentation marks read; doc_read is idempotent and sent every time.
        store.markRead(path)
        client.docRead(path: path)
        refreshStrips()
        // Focus rule: opening a peek never moves keyboard focus off the terminal.
        window?.makeFirstResponder(terminalView)
    }

    func hidePeek() {
        rootView.setPeekVisible(false)
        refreshStrips()
        window?.makeFirstResponder(terminalView)
    }

    /// ⌘⏎ (key or peek-header chip): land the peeked doc as a card on the board,
    /// or remove it if already placed, closing the peek either way. No 4-tile cap
    /// (the cap was a grid-template constraint — removed per Phase 2).
    ///
    /// TODO(Phase 3): retarget to "land as card at gravity position" (right of the
    /// caller terminal card) once gravity/shelf land; this fixed scatter slot is
    /// the Phase 2c placeholder.
    func togglePinPeeked() {
        guard rootView.peekVisible, let path = peekPath else { return }
        if isOnBoard(path) {
            rootView.board.removeCard(id: .doc(path))
        } else {
            landDocCard(path: path, frame: scatterFrame(docSlot: boardDocPaths.count))
        }
        persistLayout()
        refreshStrips()
        hidePeek()
    }

    private func refreshPeek(_ path: String) {
        rootView.peek.present(path: path, doc: store.doc(for: path), markdown: readMarkdown(path))
    }

    private func readMarkdown(_ path: String) -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return "could not read `\(path)`\n\n```\n\(error.localizedDescription)\n```\n"
        }
    }
}
