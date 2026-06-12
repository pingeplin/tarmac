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

    init(window: NSWindow, rootView: RootView) {
        self.window = window
        self.rootView = rootView
        self.client = DaemonClient()

        terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminalView.font = Theme.mono(12)
        terminalView.nativeBackgroundColor = Theme.termBg
        terminalView.nativeForegroundColor = Theme.muted
        terminalView.caretColor = Theme.agent.withAlphaComponent(0.9)
        terminalView.optionAsMetaKey = true
        termDelegate.controller = self
        terminalView.terminalDelegate = termDelegate
        rootView.attachTerminal(terminalView)

        store.onChange = { [weak self] in self?.docsChanged() }
        store.onFileChange = { [weak self] path in self?.rootView.dock.pulse(path) }
        rootView.dock.onPeek = { [weak self] path in self?.openPeek(path) }
        rootView.dock.onToggleIndex = { [weak self] in self?.toggleIndex() }
        rootView.index.onPeek = { [weak self] path in self?.openPeek(path) }
        rootView.index.onToggleIndex = { [weak self] in self?.toggleIndex() }
        rootView.peek.onPin = { [weak self] in self?.togglePinPeeked() }
        rootView.peek.onClose = { [weak self] in self?.hidePeek() }
        rootView.desk.docContent = { [weak self] path in self?.readMarkdown(path) ?? "" }
        rootView.desk.onOrderChanged = { [weak self] in self?.deskOrderChanged() }
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
                // An active drag swallows esc ahead of peek/toast dismissal
                // (crib-desk-tiles §5 DECISION).
                if self.rootView.desk.cancelDrag() {
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
        case .restore(let docs, let tiles):
            store.applyRestore(docs)
            rootView.desk.setTiles(order: tileOrder(from: tiles))
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
            if (rootView.peekVisible && peekPath == doc.path) || rootView.desk.isPinned(doc.path) {
                // The doc is on screen: mark read immediately (crib-state §2.1).
                store.markRead(doc.path)
                client.docRead(path: doc.path)
                if rootView.peekVisible && peekPath == doc.path {
                    refreshPeek(doc.path)
                }
            }
        case .fileEvent(let path, let mtimeMs):
            store.applyFileEvent(path: path, mtimeMs: mtimeMs)
            if rootView.desk.isPinned(path) {
                rootView.desk.renderDoc(path: path, markdown: readMarkdown(path))
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
        // resolution for the tile label — a fact known at spawn time
        // (crib-desk-tiles §2 DECISION).
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        rootView.desk.setTermLabel((shell as NSString).lastPathComponent)
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
        var dockActive = Set(rootView.desk.pinnedPaths)
        if let peeked = activeDocPath {
            dockActive.insert(peeked)
        }
        rootView.dock.update(docs: store.docs, activePaths: dockActive)
        rootView.index.update(docs: store.docs, activePath: activeDocPath)
        rootView.desk.update(docs: store.docs)
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

    /// ⌘⏎ (key or peek-header chip): toggle pin of the peeked doc, closing the
    /// peek either way (crib-desk-tiles §4, README toggle conflict resolution);
    /// no-op without a peek. A full desk rejects the pin and keeps the peek.
    func togglePinPeeked() {
        guard rootView.peekVisible, let path = peekPath else { return }
        if rootView.desk.isPinned(path) {
            rootView.desk.unpin(path)
        } else {
            guard !rootView.desk.isFull else {
                rootView.toasts.show(title: "desk full", body: "✕ on a tile unpins it")
                return
            }
            rootView.desk.pin(path)
        }
        hidePeek()
    }

    /// Every committed pin/unpin/swap reports the full layout snapshot
    /// (docs/protocol.md `layout`; last-writer-wins).
    private func deskOrderChanged() {
        client.layout(
            dock: store.docs.map(\.path),
            tiles: rootView.desk.order.map { key in
                switch key {
                case .term: return LayoutTile(kind: "term")
                case .doc(let path): return LayoutTile(kind: "doc", path: path)
                }
            }
        )
        refreshStrips()
        window?.makeFirstResponder(terminalView)
    }

    /// `restore.tiles[]` → desk order: unknown kinds and unregistered paths
    /// are skipped per the protocol receiver rules.
    private func tileOrder(from tiles: [LayoutTile]) -> [TileKey] {
        tiles.compactMap { tile in
            switch tile.kind {
            case "term":
                return .term
            case "doc":
                guard let path = tile.path, store.doc(for: path) != nil else { return nil }
                return .doc(path)
            default:
                return nil
            }
        }
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
