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

    /// Recency order for ⌘P; last element is the most recent (latest of restore
    /// list order, doc_opened, file_event).
    private var recentDocs: [String] = []
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
        case .restore(let docs):
            var seen = Set<String>()
            recentDocs = docs.map(\.path).filter { seen.insert($0).inserted }
        case .output(let termID, let bytes):
            guard termID == currentTermID else { return }
            terminalView.feed(byteArray: [UInt8](bytes)[...])
        case .exit(let termID, let code):
            handleExit(termID: termID, code: code)
        case .docOpened(let path, _):
            bumpRecent(path)
            rootView.toasts.show(title: "doc · \((path as NSString).lastPathComponent)", body: "⌘P to peek")
            if rootView.peekVisible && peekPath == path {
                refreshPeek(path)
            }
        case .fileEvent(let path, _):
            bumpRecent(path)
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

    private func bumpRecent(_ path: String) {
        recentDocs.removeAll { $0 == path }
        recentDocs.append(path)
    }

    func togglePeek() {
        if rootView.peekVisible {
            hidePeek()
        } else {
            guard let path = recentDocs.last else {
                NSSound.beep()
                return
            }
            openPeek(path)
        }
    }

    func openPeek(_ path: String) {
        rootView.peek.present(path: path, markdown: readMarkdown(path))
        rootView.setPeekVisible(true)
        // Focus rule: opening a peek never moves keyboard focus off the terminal.
        window?.makeFirstResponder(terminalView)
    }

    func hidePeek() {
        rootView.setPeekVisible(false)
        window?.makeFirstResponder(terminalView)
    }

    private func refreshPeek(_ path: String) {
        rootView.peek.render(markdown: readMarkdown(path))
    }

    private func readMarkdown(_ path: String) -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return "could not read `\(path)`\n\n```\n\(error.localizedDescription)\n```\n"
        }
    }
}
