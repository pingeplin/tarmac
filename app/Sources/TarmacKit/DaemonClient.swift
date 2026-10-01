import Foundation

/// The app's one long-lived connection to tarmacd — the Swift twin of
/// `desktop/src-tauri/src/bridge.rs`'s connection loop. `start()` runs it on a
/// thread of its own: connect (spawning the daemon on a miss), handshake,
/// replace a daemon of another version, then read frames until the link drops
/// and reconnect on the `Reconnect` backoff. `Message`s and `ConnectionStatus`
/// changes are delivered on `deliveryQueue` (main by default), in the order
/// they happened.
///
/// Requests are fire-and-forget (the protocol has no request ids). While no
/// handshake has completed they are queued, unbounded and in order, and go out
/// after the next one does; once the client has given up or been closed they
/// are dropped.
public final class DaemonClient: @unchecked Sendable {
    /// Every wait the connection loop makes. `standard` is the app's; tests
    /// shorten them.
    public struct Timing: Sendable {
        /// How long a connect pass keeps retrying the socket after a miss.
        public var connectRetryBudget: TimeInterval
        public var connectRetryInterval: TimeInterval
        /// How long a restart waits for the dying daemon to remove its socket.
        public var restartWaitBudget: TimeInterval
        public var restartPollInterval: TimeInterval
        /// Seconds to wait before reconnect attempt `n` (1-based); nil gives up.
        public var reconnectDelay: @Sendable (Int) -> TimeInterval?

        public init(
            connectRetryBudget: TimeInterval = 3,
            connectRetryInterval: TimeInterval = 0.1,
            restartWaitBudget: TimeInterval = 2,
            restartPollInterval: TimeInterval = 0.05,
            reconnectDelay: @escaping @Sendable (Int) -> TimeInterval? = Reconnect.delay(forAttempt:)
        ) {
            self.connectRetryBudget = connectRetryBudget
            self.connectRetryInterval = connectRetryInterval
            self.restartWaitBudget = restartWaitBudget
            self.restartPollInterval = restartPollInterval
            self.reconnectDelay = reconnectDelay
        }

        public static let standard = Timing()
    }

    public let socketPath: String
    public let channel: ChannelPaths.Channel
    /// Sent as `hello.app_version`, and compared with `hello_ok.daemon_version`
    /// to spot a stale daemon. nil names no version and restarts nothing — see
    /// `AppVersion`.
    public let appVersion: String?

    /// Set both before `start()`.
    public var onMessage: (@Sendable (Message) -> Void)?
    public var onStatus: (@Sendable (ConnectionStatus) -> Void)?

    private let environment: [String: String]
    private let executableDir: String
    private let timing: Timing
    private let deliveryQueue: DispatchQueue
    private let writeQueue = DispatchQueue(label: "tarmac.daemon.write")
    private let wake = DispatchSemaphore(value: 0)

    private let stateLock = NSLock()
    private var started = false
    private var closed = false
    /// The loop has ended, by `close()` or by running out of reconnect budget.
    private var finished = false
    /// The socket the loop is on, so `close()` can interrupt a blocked read.
    private var activeFD: Int32 = -1
    private var child: pid_t?
    private var replaced: DaemonLaunch.Replaced?

    /// Touched on `writeQueue` only. `link` is the socket requests may be
    /// written to: set once a handshake has proceeded, cleared when it drops.
    private var link: Int32 = -1
    private var pending: [Data] = []

    /// `channel` defaults to the build configuration (`ChannelPaths.Channel.build`,
    /// the one audited `#if DEBUG` mapping). An explicit `socketPath` wins over
    /// both it and `TARMAC_SOCKET`. `environment` is the app's own: it is where
    /// `TARMAC_SOCKET` and `TARMAC_DAEMON` are read, and what a spawned daemon
    /// inherits. `executableDir` is where a bundled `tarmacd` sits.
    public init(
        socketPath: String? = nil,
        channel: ChannelPaths.Channel = .build,
        appVersion: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableDir: String = DaemonClient.runningExecutableDir,
        timing: Timing = .standard,
        deliveryQueue: DispatchQueue = .main
    ) {
        self.socketPath = socketPath ?? Self.resolveSocketPath(env: environment, channel: channel)
        self.channel = channel
        self.appVersion = appVersion
        self.environment = environment
        self.executableDir = executableDir
        self.timing = timing
        self.deliveryQueue = deliveryQueue
    }

    public static var runningExecutableDir: String {
        Bundle.main.executableURL?.deletingLastPathComponent().path ?? ""
    }

    /// `TARMAC_SOCKET` override (non-empty wins verbatim), else the per-channel
    /// default under `$HOME` (spec 2606.0003).
    public static func resolveSocketPath(
        env: [String: String] = ProcessInfo.processInfo.environment,
        channel: ChannelPaths.Channel = .build
    ) -> String {
        ChannelPaths.socketPath(override: env["TARMAC_SOCKET"], home: ChannelPaths.home(env: env), channel: channel)
    }

    /// The macOS `sockaddr_un.sun_path` capacity in bytes (incl. the NUL
    /// terminator). `connect` accepts a path iff its byte length is strictly
    /// less than this — leaving room for the NUL.
    public static let sunPathCapacity = 104

    /// PURE: does `path` fit a `sockaddr_un`? (byte length `< sunPathCapacity`).
    /// A path that does not fails the connect with a reason rather than being
    /// truncated into some other path (spec S8/S8b).
    public static func fitsUnixSocketPath(_ path: String) -> Bool {
        path.utf8.count < sunPathCapacity
    }

    // MARK: - Lifecycle

    private static let closeDrainBudget: TimeInterval = 0.5

    /// Starts the connection loop. Later calls do nothing.
    public func start() {
        stateLock.lock()
        let first = !started
        started = true
        stateLock.unlock()
        guard first else { return }
        let thread = Thread { [self] in run() }
        thread.name = "tarmac.daemon.connection"
        thread.start()
    }

    /// Ends the link for good: no reconnect, and nothing more is delivered. The
    /// daemon, and a daemon this client spawned, are left running.
    ///
    /// Requests already made are written first — the layout flushed on quit is
    /// one — but only for `closeDrainBudget`: a daemon that has stopped reading
    /// must not be able to hang the app's exit.
    public func close() {
        let drained = DispatchSemaphore(value: 0)
        writeQueue.async { drained.signal() }
        _ = drained.wait(timeout: .now() + Self.closeDrainBudget)
        stateLock.lock()
        closed = true
        finished = true
        if activeFD >= 0 { shutdown(activeFD, SHUT_RDWR) }
        stateLock.unlock()
        wake.signal()
    }

    /// The daemon a version-mismatch restart replaced, once there was one. It
    /// is never cleared: the restart happens at most once per process.
    public var daemonReplaced: DaemonLaunch.Replaced? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return replaced
    }

    /// The pid of the daemon this client spawned, while that daemon is alive.
    public var spawnedDaemonPid: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return liveChild().map(Int.init)
    }

    // MARK: - Send

    public func send(_ message: Message) {
        guard let framed = try? Framing.frame(message.encodedPayload()) else { return }
        writeQueue.async { [self] in
            guard !isFinished else { return }
            guard link >= 0 else {
                pending.append(framed)
                return
            }
            if !DaemonSocket.write(framed, to: link) { dropLink() }
        }
    }

    public func spawnTerm(
        termID: String,
        cols: Int,
        rows: Int,
        cwd: String?,
        cmd: [String]?,
        boardID: String? = nil,
        inheritCwdFrom: String? = nil
    ) {
        send(.spawnTerm(
            termID: termID, cols: cols, rows: rows, cwd: cwd, cmd: cmd,
            boardID: boardID, inheritCwdFrom: inheritCwdFrom
        ))
    }

    public func input(termID: String, bytes: Data) {
        send(.input(termID: termID, bytes: bytes))
    }

    public func resize(termID: String, cols: Int, rows: Int) {
        send(.resize(termID: termID, cols: cols, rows: rows))
    }

    public func open(path: String, termID: String? = nil, boardID: String? = nil) {
        send(.open(path: path, termID: termID, boardID: boardID))
    }

    public func docRead(path: String) {
        send(.docRead(path: path))
    }

    public func layout(dock: [String], tiles: [LayoutTile], board: BoardViewport? = nil, boardID: String? = nil) {
        send(.layout(dock: dock, tiles: tiles, board: board, boardID: boardID))
    }

    /// M3: make `boardID` the active board (the daemon replies with board_list +
    /// that board's restore).
    public func boardSwitch(boardID: String) {
        send(.boardSwitch(boardID: boardID))
    }

    /// M3: mint a fresh board (the daemon assigns the slug id and makes it active).
    public func boardCreate() {
        send(.boardCreate)
    }

    /// P5.4: rename `boardID` (an empty `name` clears it back to the slug). The
    /// daemon re-pushes board_list with the new name.
    public func boardRename(boardID: String, name: String) {
        send(.boardRename(boardID: boardID, name: name))
    }

    /// P5.4: delete `boardID`. The daemon refuses the last board and, when the
    /// deleted board was active, fixes the active board and re-pushes board_list +
    /// the new active board's restore.
    public func boardDelete(boardID: String) {
        send(.boardDelete(boardID: boardID))
    }

    /// issue #15: terminate one terminal's pty (the daemon SIGHUPs its process
    /// group). Used by ⌘W to close a single terminal card.
    public func termClose(termID: String) {
        send(.termClose(termID: termID))
    }

    /// issue #34: forget a doc (registry, dock, watcher). No reply frame.
    public func docClose(path: String) {
        send(.docClose(path: path))
    }

    /// issue #89: re-stat a doc now; the daemon answers with the usual
    /// `file_event`, changed or not.
    public func docRefresh(path: String) {
        send(.docRefresh(path: path))
    }

    /// issue #41: ask for one terminal's scrollback ring. Exactly one
    /// `scrollback` comes back, even for an unknown terminal — but a daemon that
    /// predates the type never answers, so the caller bounds its wait.
    public func scrollbackRequest(termID: String) {
        send(.scrollbackRequest(termID: termID))
    }

    // MARK: - The connection loop

    private func run() {
        var spawned = false
        var alreadyRestarted = false
        var attempt = 0
        while !isFinished {
            switch establish(spawned: &spawned) {
            case .success(let fd):
                attempt = 0
                emit(.connected)
                let restarted = converse(over: fd, alreadyRestarted: alreadyRestarted)
                release(fd)
                if restarted {
                    // No backoff, and spawning is allowed again: the daemon
                    // this app may have started is the one it just terminated.
                    spawned = false
                    alreadyRestarted = true
                    continue
                }
                emit(.closed)
            case .failure(let failure):
                emit(.connectFailed(failure.detail))
            }
            attempt += 1
            guard let delay = timing.reconnectDelay(attempt) else {
                emit(.gaveUp)
                break
            }
            guard pause(delay) else { break }
        }
        finish()
    }

    private struct ConnectFailure: Error {
        var detail: String
    }

    /// One connect pass: the socket, else spawn the daemon — unless one this
    /// client started is still alive — and retry until the budget is spent.
    private func establish(spawned: inout Bool) -> Result<Int32, ConnectFailure> {
        guard Self.fitsUnixSocketPath(socketPath) else {
            return .failure(ConnectFailure(detail: ConnectionStatus.socketPathTooLong(socketPath)))
        }
        if let fd = connectOnce() { return .success(fd) }
        if let launched = spawnIfAllowed(alreadySpawned: spawned) {
            spawned = launched
        }
        let deadline = Date().addingTimeInterval(timing.connectRetryBudget)
        while pause(timing.connectRetryInterval) {
            if let fd = connectOnce() { return .success(fd) }
            if Date() >= deadline { break }
        }
        return .failure(ConnectFailure(detail: ConnectionStatus.noDaemon(at: socketPath)))
    }

    /// The handshake, the version check, then frames until the link drops.
    /// Returns true iff the daemon was told to exit and must be replaced.
    private func converse(over fd: Int32, alreadyRestarted: Bool) -> Bool {
        guard let hello = try? Framing.frame(Message.hello(role: "app", v: 1, appVersion: appVersion).encodedPayload()),
            DaemonSocket.write(hello, to: fd),
            let payload = DaemonSocket.readFrame(from: fd),
            let first = try? Message.decode(payload: payload)
        else { return false }

        var reportedVersion: String?
        var reportedPid: Int?
        if case .helloOK(_, let daemonVersion, let daemonPid, _, _) = first {
            reportedVersion = daemonVersion
            reportedPid = daemonPid
        }
        if DaemonLaunch.shouldRestart(
            expected: appVersion, reported: reportedVersion, alreadyRestarted: alreadyRestarted
        ) {
            replaceDaemon(reportedVersion: reportedVersion, reportedPid: reportedPid)
            return true
        }

        stateLock.lock()
        DaemonLaunch.noteProceeding(&replaced, reported: reportedVersion)
        stateLock.unlock()
        deliver(first)
        raiseLink(fd)
        while let payload = DaemonSocket.readFrame(from: fd) {
            // A frame that does not decode is skipped; only a stream that can
            // no longer be read ends the connection.
            if let message = try? Message.decode(payload: payload) { deliver(message) }
        }
        lowerLink()
        return false
    }

    /// SIGTERM the stale daemon, then wait for it to remove its socket: a new
    /// daemon that still finds a live one behind the socket quits instead of
    /// taking over. Bounded, so a wedged daemon still lets the app proceed.
    private func replaceDaemon(reportedVersion: String?, reportedPid: Int?) {
        emit(.restarting)
        stateLock.lock()
        replaced = DaemonLaunch.Replaced(from: reportedVersion, to: nil)
        let spawnedChild = liveChild().map(Int.init)
        stateLock.unlock()
        if let pid = DaemonLaunch.restartTarget(reportedPid: reportedPid, spawnedChildPid: spawnedChild) {
            kill(pid_t(pid), SIGTERM)
        }
        let deadline = Date().addingTimeInterval(timing.restartWaitBudget)
        while FileManager.default.fileExists(atPath: socketPath), Date() < deadline {
            guard pause(timing.restartPollInterval) else { return }
        }
    }

    // MARK: - Spawn

    /// Whether the launch produced a daemon; nil when none was attempted. Under
    /// `stateLock`, so `close()` — which takes it — is never followed by a spawn.
    private func spawnIfAllowed(alreadySpawned: Bool) -> Bool? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else { return nil }
        let priorChildExited = liveChild() == nil
        guard DaemonLaunch.maySpawn(alreadySpawned: alreadySpawned, priorChildExited: priorChildExited),
            let daemon = DaemonLaunch.resolveDaemonPath(
                env: environment, executableDir: executableDir, exists: FileManager.default.fileExists(atPath:)
            )
        else { return nil }
        child = DaemonSpawner.spawn(
            program: daemon,
            environment: DaemonLaunch.childEnvironment(base: environment, daemonPath: daemon),
            logPath: DaemonLaunch.logPath(socketPath: socketPath)
        )
        return child != nil
    }

    /// The spawned daemon, if it is still running. One that has exited is
    /// forgotten, so its pid — free to be reused by any process — is never
    /// signalled. Caller holds `stateLock`.
    private func liveChild() -> pid_t? {
        guard let pid = child else { return nil }
        if DaemonLaunch.priorChildExited(waitResult: DaemonSpawner.waitResult(of: pid)) {
            child = nil
        }
        return child
    }

    // MARK: - Socket

    private func connectOnce() -> Int32? {
        guard let sock = DaemonSocket.connect(to: socketPath) else { return nil }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else {
            Darwin.close(sock)
            return nil
        }
        activeFD = sock
        return sock
    }

    /// Closing is the loop's alone, and only after `close()` can no longer
    /// reach the descriptor — a number the kernel may hand out again at once.
    private func release(_ fd: Int32) {
        stateLock.lock()
        activeFD = -1
        stateLock.unlock()
        Darwin.close(fd)
    }

    private func raiseLink(_ fd: Int32) {
        writeQueue.sync {
            link = fd
            let queued = pending
            pending = []
            for (index, framed) in queued.enumerated() {
                if DaemonSocket.write(framed, to: fd) { continue }
                pending = Array(queued[(index + 1)...])
                dropLink()
                break
            }
        }
    }

    private func lowerLink() {
        writeQueue.sync { link = -1 }
    }

    /// A write failed: the request is lost, later ones queue, and the reader is
    /// woken to find the link dead. On `writeQueue`.
    private func dropLink() {
        shutdown(link, SHUT_RDWR)
        link = -1
    }

    // MARK: - State

    private var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finished
    }

    private var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    private func finish() {
        stateLock.lock()
        finished = true
        stateLock.unlock()
        writeQueue.sync { pending = [] }
    }

    /// Sleeps `seconds`, or until `close()`. False once the loop must stop.
    private func pause(_ seconds: TimeInterval) -> Bool {
        if isFinished { return false }
        _ = wake.wait(timeout: .now() + seconds)
        return !isFinished
    }

    private func emit(_ status: ConnectionStatus) {
        deliveryQueue.async { [self] in
            if !isClosed { onStatus?(status) }
        }
    }

    private func deliver(_ message: Message) {
        deliveryQueue.async { [self] in
            if !isClosed { onMessage?(message) }
        }
    }
}
