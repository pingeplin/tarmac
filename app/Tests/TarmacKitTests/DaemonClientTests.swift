import XCTest
import TarmacKit

/// A stand-in for `tarmacd`: binds a real Unix socket, accepts connections one
/// after another, records every frame each one writes, and can push frames
/// back or drop a link. It is what lets the client's wiring be tested end to
/// end without a daemon binary.
private final class FakeDaemon: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let state = NSCondition()
    private var connections: [Int32] = []
    private var frames: [[Data]] = []
    private var ended: Set<Int> = []
    private var frameBudgets: [Int: Int] = [:]
    private var stopped = false

    static func temporaryPath() -> String {
        NSTemporaryDirectory() + "td-\(UUID().uuidString.prefix(8)).sock"
    }

    init(path: String = FakeDaemon.temporaryPath()) throws {
        self.path = path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                precondition(strlen(src) < dst.count, "temp socket path too long")
                _ = memcpy(dst.baseAddress!, src, strlen(src) + 1)
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Non-blocking, so `shutDown` ends the accept loop without relying on
        // close() waking a thread parked in accept().
        guard bound == 0, listen(listener, 8) == 0, fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { shutDown() }

    /// Stop listening, drop every link and remove the socket file, as a daemon
    /// that exits does.
    func shutDown() {
        state.lock()
        let wasStopped = stopped
        stopped = true
        let open = connections
        state.unlock()
        guard !wasStopped else { return }
        open.forEach { shutdown($0, SHUT_RDWR) }
        close(listener)
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            state.lock()
            let done = stopped
            state.unlock()
            if done { return }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else {
                usleep(2_000)
                continue
            }
            _ = fcntl(fd, F_SETFL, 0)
            state.lock()
            let index = connections.count
            connections.append(fd)
            frames.append([])
            state.broadcast()
            state.unlock()
            Thread.detachNewThread { [self] in serve(index, fd) }
        }
    }

    private func serve(_ index: Int, _ fd: Int32) {
        var decoder = Framing.StreamDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else {
                state.lock()
                ended.insert(index)
                state.broadcast()
                state.unlock()
                return
            }
            decoder.append(Data(buffer[..<n]))
            while let frame = try? decoder.nextFrame() {
                state.lock()
                frames[index].append(frame)
                let wedged = frames[index].count == frameBudgets[index]
                state.broadcast()
                state.unlock()
                if wedged { return }
            }
        }
    }

    /// Connection `index` stops reading once it holds `count` frames, as a
    /// daemon that has wedged does: its socket stays open and fills up. Set
    /// before the connection is made.
    func stopReading(after count: Int, on index: Int = 0) {
        state.lock()
        frameBudgets[index] = count
        state.unlock()
    }

    /// Whether connection `index` read to the end of its stream within
    /// `timeout`: the other side hung up.
    func sawEnd(of index: Int = 0, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        state.lock()
        defer { state.unlock() }
        while !ended.contains(index), state.wait(until: deadline) {}
        return ended.contains(index)
    }

    var connectionCount: Int {
        state.lock()
        defer { state.unlock() }
        return connections.count
    }

    /// Whether `count` connections were accepted within `timeout`.
    func accepted(_ count: Int, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        state.lock()
        defer { state.unlock() }
        while connections.count < count, state.wait(until: deadline) {}
        return connections.count >= count
    }

    /// The first `count` payloads connection `index` sent, waiting up to
    /// `timeout` for them. Returns what arrived, so a short read fails the
    /// caller's assertion.
    func received(_ count: Int, on index: Int = 0, timeout: TimeInterval = 3) -> [Data] {
        let deadline = Date().addingTimeInterval(timeout)
        state.lock()
        defer { state.unlock() }
        while frames.count <= index || frames[index].count < count, state.wait(until: deadline) {}
        return frames.count > index ? Array(frames[index].prefix(count)) : []
    }

    func push(_ message: Message, on index: Int = 0) throws {
        try push(payload: message.encodedPayload(), on: index)
    }

    func push(payload: Data, on index: Int = 0) throws {
        try push(bytes: Framing.frame(payload), on: index)
    }

    /// `bytes` as they are, with no frame around them.
    func push(bytes: Data, on index: Int = 0) throws {
        guard accepted(index + 1) else { throw POSIXError(.ETIMEDOUT) }
        state.lock()
        let fd = connections[index]
        state.unlock()
        try bytes.withUnsafeBytes { raw in
            guard write(fd, raw.baseAddress, raw.count) == raw.count else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Hang up on connection `index`, as a daemon that died does.
    func drop(_ index: Int = 0) {
        guard accepted(index + 1) else { return }
        state.lock()
        let fd = connections[index]
        state.unlock()
        shutdown(fd, SHUT_RDWR)
    }

    /// Close connection `index`, which must have stopped reading. Unlike
    /// `drop`, this fails a write the client is blocked in: a peer's shutdown
    /// leaves that writer asleep, a peer's close does not.
    func closeWedged(_ index: Int = 0) {
        guard accepted(index + 1) else { return }
        state.lock()
        let fd = connections[index]
        connections[index] = -1
        state.unlock()
        close(fd)
    }
}

/// Everything a client reported, in order, with a bounded wait for the next.
private final class Log<Entry: Sendable>: @unchecked Sendable {
    private let state = NSCondition()
    private var entries: [Entry] = []

    func record(_ entry: Entry) {
        state.lock()
        entries.append(entry)
        state.broadcast()
        state.unlock()
    }

    var all: [Entry] {
        state.lock()
        defer { state.unlock() }
        return entries
    }

    /// The first `count` entries, waiting up to `timeout` for them.
    func first(_ count: Int, timeout: TimeInterval = 3) -> [Entry] {
        let deadline = Date().addingTimeInterval(timeout)
        state.lock()
        defer { state.unlock() }
        while entries.count < count, state.wait(until: deadline) {}
        return Array(entries.prefix(count))
    }

    /// Whether an entry satisfying `predicate` arrived within `timeout`.
    func saw(timeout: TimeInterval = 3, _ predicate: (Entry) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        state.lock()
        defer { state.unlock() }
        while !entries.contains(where: predicate), state.wait(until: deadline) {}
        return entries.contains(where: predicate)
    }
}

/// A `tarmacd` that is a shell script, in a directory of its own: it records
/// each launch and the `PATH` it was given, writes to both streams, then
/// listens on `$TARMAC_SOCKET` and answers a connection with a canned frame.
private struct ScriptedDaemon {
    let dir: String
    var socket: String { dir + "/tarmacd.sock" }
    var log: String { dir + "/tarmacd.log" }

    init() throws {
        dir = NSTemporaryDirectory() + "tarmac-fake-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// A daemon that listens and answers with `reply`.
    @discardableResult
    func install(named name: String = "fake-tarmacd", replying reply: Message) throws -> String {
        try Framing.frame(reply.encodedPayload()).write(to: URL(fileURLWithPath: dir + "/reply"))
        return try install(named: name, body: """
            echo started
            echo oops >&2
            rm -f "$TARMAC_SOCKET"
            exec nc -lU "$TARMAC_SOCKET" < "$dir/reply"
            """)
    }

    /// A daemon that runs `body` after recording its launch.
    @discardableResult
    func install(named name: String = "fake-tarmacd", body: String) throws -> String {
        let path = dir + "/" + name
        let script = """
            #!/bin/sh
            dir=$(dirname "$0")
            echo spawned >> "$dir/launches"
            printenv PATH > "$dir/path"
            \(body)

            """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    var launches: Int {
        text("launches").split(separator: "\n").count
    }

    func text(_ name: String) -> String {
        (try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)) ?? ""
    }

    func environment(daemon: String? = nil) -> [String: String] {
        var environment = ["TARMAC_SOCKET": socket, "PATH": "/usr/bin:/bin"]
        environment["TARMAC_DAEMON"] = daemon
        return environment
    }
}

private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { usleep(10_000) }
    return condition()
}

/// A request too large for the socket's buffers: its write cannot finish until
/// the daemon reads.
private let megabyte = Message.input(termID: "t1", bytes: Data(count: 1 << 20))

/// Bytes this process holds on the heap, over every malloc zone.
private func heapBytesInUse() -> Int {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return statistics.size_in_use
}

extension DaemonClient.Timing {
    /// Short waits, and a reconnect that never runs out. The connect budget
    /// stays long: it only bounds a connect that is going to fail, and the first
    /// run of a freshly written daemon script can take a while to start.
    fileprivate static let fast = DaemonClient.Timing(
        connectRetryBudget: 5, connectRetryInterval: 0.02,
        restartWaitBudget: 0.3, restartPollInterval: 0.02,
        reconnectDelay: { _ in 0.02 }
    )

    /// For a connect that is expected to miss.
    fileprivate func givingUpConnectAfter(_ budget: TimeInterval) -> DaemonClient.Timing {
        var timing = self
        timing.connectRetryBudget = budget
        return timing
    }

    fileprivate func reconnecting(_ delay: @escaping @Sendable (Int) -> TimeInterval?) -> DaemonClient.Timing {
        var timing = self
        timing.reconnectDelay = delay
        return timing
    }
}

/// The client against a real socket: what it says first, what each send helper
/// puts on the wire, what reaches the app, and how the link is kept up.
final class DaemonClientTests: XCTestCase {
    private let delivery = DispatchQueue(label: "tarmac.test.delivery")
    private var clients: [DaemonClient] = []
    private var victims: [pid_t] = []

    override func tearDown() {
        for client in clients {
            client.close()
            client.spawnedDaemonPid.map { _ = kill(pid_t($0), SIGKILL) }
        }
        clients = []
        for pid in victims {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        victims = []
    }

    private func makeClient(
        _ socketPath: String? = nil,
        appVersion: String? = nil,
        environment: [String: String] = [:],
        executableDir: String = "/nonexistent",
        timing: DaemonClient.Timing = .fast
    ) -> (client: DaemonClient, statuses: Log<ConnectionStatus>, messages: Log<Message>) {
        let client = DaemonClient(
            socketPath: socketPath, appVersion: appVersion, environment: environment,
            executableDir: executableDir, timing: timing, deliveryQueue: delivery
        )
        let statuses = Log<ConnectionStatus>()
        let messages = Log<Message>()
        client.onStatus = { statuses.record($0) }
        client.onMessage = { messages.record($0) }
        clients.append(client)
        return (client, statuses, messages)
    }

    /// A process standing in for a daemon the client may be told to terminate.
    private func victim() throws -> pid_t {
        let pid = try XCTUnwrap(DaemonSpawner.spawn(
            program: "/bin/sleep", arguments: ["30"], environment: [:], logPath: "/dev/null"
        ))
        victims.append(pid)
        return pid
    }

    /// The signal that killed `pid`, or nil if it is still running after `timeout`.
    private func signalThatKilled(_ pid: pid_t, timeout: TimeInterval = 3) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) == 0 {
            if Date() >= deadline { return nil }
            usleep(10_000)
        }
        victims.removeAll { $0 == pid }
        return status & 0x7f
    }

    private func messages(_ payloads: [Data]) throws -> [Message] {
        try payloads.map { try Message.decode(payload: $0) }
    }

    /// A queued request is only visible as the memory it holds: sixteen
    /// megabytes of them must leave next to none of it behind.
    private func assertRequestsAreDropped(
        by client: DaemonClient, file: StaticString = #filePath, line: UInt = #line
    ) {
        let before = heapBytesInUse()
        for _ in 0..<16 { client.send(megabyte) }
        XCTAssertTrue(
            eventually { heapBytesInUse() - before < 4 << 20 },
            "\(heapBytesInUse() - before) bytes are still held", file: file, line: line
        )
    }

    // MARK: - Handshake

    /// 2609.0012: the app names its version in `hello`; it is the only source of
    /// the app version `tarmac --version` reports.
    func testHelloNamesTheAppVersion() throws {
        let daemon = try FakeDaemon()
        makeClient(daemon.path, appVersion: "9.9.9").client.start()

        XCTAssertEqual(try messages(daemon.received(1)), [.hello(role: "app", v: 1, appVersion: "9.9.9")])
    }

    /// A client that names no version sends conformance vector 2, byte for byte.
    func testHelloWithoutAVersionIsVector2() throws {
        let daemon = try FakeDaemon()
        makeClient(daemon.path).client.start()

        XCTAssertEqual(
            daemon.received(1),
            [hexData("83 a1 74 a5 68 65 6c 6c 6f a4 72 6f 6c 65 a3 61 70 70 a1 76 01")]
        )
    }

    /// `hello_ok` reaches the app, and everything after it in order.
    func testMessagesReachTheAppInOrder() throws {
        let daemon = try FakeDaemon()
        let (client, _, inbox) = makeClient(daemon.path, appVersion: "0.13.1")
        client.start()

        let sent: [Message] = [
            .helloOK(v: 1, daemonVersion: "0.13.1", daemonPid: 4242),
            .boardList(boards: [BoardMeta(boardID: "board-0")], active: "board-0"),
            .bell(termID: "t1"),
        ]
        for message in sent { try daemon.push(message) }
        XCTAssertEqual(inbox.first(sent.count), sent)
    }

    // MARK: - Sending

    /// One helper per app → daemon message, each writing exactly its frame, in
    /// the order sent.
    func testEverySendHelperWritesItsFrame() throws {
        let daemon = try FakeDaemon()
        let (client, _, inbox) = makeClient(daemon.path)
        client.start()
        try daemon.push(.helloOK(v: 1))
        XCTAssertEqual(inbox.first(1), [.helloOK(v: 1)])

        let tile = LayoutTile(kind: "term", x: 1, y: 2, w: 3, h: 4, z: 0, termID: "t1")
        let board = BoardViewport(zoom: 1, cx: 0, cy: 0)
        client.spawnTerm(termID: "t1", cols: 80, rows: 24, cwd: nil, cmd: nil)
        client.spawnTerm(
            termID: "t2", cols: 80, rows: 24, cwd: nil, cmd: nil, boardID: "board-1", inheritCwdFrom: "t1"
        )
        client.input(termID: "t1", bytes: Data("ls\n".utf8))
        client.resize(termID: "t1", cols: 120, rows: 40)
        client.termClose(termID: "t1")
        client.scrollbackRequest(termID: "t1")
        client.open(path: "/a.md")
        client.open(path: "/a.md", termID: "t1", boardID: "board-1")
        client.docRead(path: "/a.md")
        client.docClose(path: "/a.md")
        client.docRefresh(path: "/a.md")
        client.layout(dock: ["/a.md"], tiles: [tile], board: board, boardID: "board-1")
        client.boardSwitch(boardID: "board-1")
        client.boardCreate()
        client.boardRename(boardID: "board-1", name: "infra")
        client.boardDelete(boardID: "board-1")

        let expected: [Message] = [
            .hello(role: "app", v: 1),
            .spawnTerm(termID: "t1", cols: 80, rows: 24, cwd: nil, cmd: nil),
            .spawnTerm(termID: "t2", cols: 80, rows: 24, cwd: nil, cmd: nil, boardID: "board-1", inheritCwdFrom: "t1"),
            .input(termID: "t1", bytes: Data("ls\n".utf8)),
            .resize(termID: "t1", cols: 120, rows: 40),
            .termClose(termID: "t1"),
            .scrollbackRequest(termID: "t1"),
            .open(path: "/a.md", termID: nil),
            .open(path: "/a.md", termID: "t1", boardID: "board-1"),
            .docRead(path: "/a.md"),
            .docClose(path: "/a.md"),
            .docRefresh(path: "/a.md"),
            .layout(dock: ["/a.md"], tiles: [tile], board: board, boardID: "board-1"),
            .boardSwitch(boardID: "board-1"),
            .boardCreate,
            .boardRename(boardID: "board-1", name: "infra"),
            .boardDelete(boardID: "board-1"),
        ]
        XCTAssertEqual(try messages(daemon.received(expected.count)), expected)
    }

    /// Nothing follows `hello` until the daemon has answered it: the answer
    /// decides whether this daemon is kept, and a request must not go to one
    /// that is about to be replaced.
    func testRequestsWaitForTheHandshake() throws {
        let daemon = try FakeDaemon()
        let (client, _, _) = makeClient(daemon.path)
        client.boardCreate()
        client.start()
        client.termClose(termID: "t1")

        XCTAssertEqual(try messages(daemon.received(2, timeout: 0.3)), [.hello(role: "app", v: 1)])

        try daemon.push(.helloOK(v: 1))
        XCTAssertEqual(
            try messages(daemon.received(3)),
            [.hello(role: "app", v: 1), .boardCreate, .termClose(termID: "t1")]
        )
    }

    /// Requests made while the link is down are kept, and go out in order once
    /// the next connection has completed its handshake.
    func testRequestsMadeWhileDisconnectedAreSentAfterTheReconnect() throws {
        let daemon = try FakeDaemon()
        let (client, statuses, _) = makeClient(daemon.path, timing: .fast.reconnecting { _ in 0.3 })
        client.start()
        try daemon.push(.helloOK(v: 1))
        daemon.drop()
        XCTAssertEqual(statuses.first(2), [.connected, .closed])

        client.boardSwitch(boardID: "board-1")
        client.docClose(path: "/a.md")

        XCTAssertEqual(try messages(daemon.received(1, on: 1)), [.hello(role: "app", v: 1)])
        try daemon.push(.helloOK(v: 1), on: 1)
        XCTAssertEqual(
            try messages(daemon.received(3, on: 1)),
            [.hello(role: "app", v: 1), .boardSwitch(boardID: "board-1"), .docClose(path: "/a.md")]
        )
    }

    /// A daemon that dies while the queue is being flushed costs the request
    /// it was being sent, and no other: those behind it go to the next link.
    func testAWriteThatFailsMidFlushKeepsTheRequestsBehindIt() throws {
        let daemon = try FakeDaemon()
        daemon.stopReading(after: 2)
        let (client, _, _) = makeClient(daemon.path)
        client.boardCreate()
        client.send(megabyte)
        client.boardSwitch(boardID: "board-1")
        client.docClose(path: "/a.md")
        client.start()

        try daemon.push(.helloOK(v: 1))
        XCTAssertEqual(try messages(daemon.received(2)), [.hello(role: "app", v: 1), .boardCreate])
        daemon.closeWedged()

        try daemon.push(.helloOK(v: 1), on: 1)
        XCTAssertEqual(
            try messages(daemon.received(3, on: 1)),
            [.hello(role: "app", v: 1), .boardSwitch(boardID: "board-1"), .docClose(path: "/a.md")]
        )
    }

    // MARK: - Status

    /// The link reads as connected as soon as the socket is, before `hello_ok`.
    func testConnectedIsReportedBeforeTheHandshakeCompletes() throws {
        let daemon = try FakeDaemon()
        let (client, statuses, inbox) = makeClient(daemon.path)
        client.start()

        XCTAssertEqual(statuses.first(1), [.connected])
        XCTAssertEqual(inbox.all, [])
    }

    /// A dropped link is reported with the bridge's reason, then re-made.
    func testADroppedLinkIsReportedAndReconnected() throws {
        let daemon = try FakeDaemon()
        let (client, statuses, _) = makeClient(daemon.path)
        client.start()
        try daemon.push(.helloOK(v: 1))
        XCTAssertTrue(daemon.accepted(1))
        daemon.drop()

        XCTAssertEqual(statuses.first(3), [.connected, .closed, .connected])
        XCTAssertTrue(daemon.accepted(2))
    }

    /// A frame that does not decode is skipped; the link stays up.
    func testAMalformedFrameIsSkipped() throws {
        let daemon = try FakeDaemon()
        let (client, statuses, inbox) = makeClient(daemon.path)
        client.start()
        try daemon.push(.helloOK(v: 1))
        try daemon.push(payload: Data([0xc1]))
        try daemon.push(.bell(termID: "t1"))

        XCTAssertEqual(inbox.first(2), [.helloOK(v: 1), .bell(termID: "t1")])
        XCTAssertEqual(statuses.all, [.connected])
    }

    /// A length past the 16 MiB cap is not a frame to wait for. The stream's
    /// frame boundaries are lost with it, so the link is dropped and re-made.
    func testAFrameLengthPastTheCapDropsTheLink() throws {
        let daemon = try FakeDaemon()
        let (client, statuses, inbox) = makeClient(daemon.path)
        client.start()
        try daemon.push(.helloOK(v: 1))
        // One write: a second would race the client hanging up, and raise SIGPIPE.
        let pastTheCap = withUnsafeBytes(of: UInt32(Framing.maxFrameLength + 1).bigEndian) { Data($0) }
        try daemon.push(bytes: pastTheCap + Framing.frame(Message.bell(termID: "t1").encodedPayload()))

        XCTAssertEqual(statuses.first(3), [.connected, .closed, .connected])
        XCTAssertEqual(inbox.all, [.helloOK(v: 1)])
    }

    /// With no daemon and nothing to spawn, each attempt fails by naming the
    /// socket, and after the backoff budget the client says so and stops.
    func testAMissingDaemonFailsEachAttemptThenGivesUp() {
        let path = FakeDaemon.temporaryPath()
        let (client, statuses, _) = makeClient(
            path, timing: .fast.givingUpConnectAfter(0.05).reconnecting { $0 <= 2 ? 0.01 : nil }
        )
        client.start()

        let failed = ConnectionStatus.connectFailed("no daemon at \(path)")
        XCTAssertEqual(statuses.first(4), [failed, failed, failed, .gaveUp])
        usleep(300_000)
        XCTAssertEqual(statuses.all.count, 4, "nothing is attempted after giving up")
    }

    /// The backoff counts attempts since the last success, not since launch.
    func testTheReconnectBudgetStartsOverAfterEachSuccessfulConnect() throws {
        let daemon = try FakeDaemon()
        let (client, statuses, _) = makeClient(daemon.path, timing: .fast.reconnecting { $0 <= 1 ? 0.01 : nil })
        client.start()
        daemon.drop(0)
        daemon.drop(1)

        XCTAssertEqual(statuses.first(5), [.connected, .closed, .connected, .closed, .connected])
    }

    /// A path too long for `sockaddr_un` fails the connect with a reason
    /// instead of being truncated into some other path.
    func testAnOverlongSocketPathFailsTheConnect() {
        let path = "/tmp/" + String(repeating: "a", count: 120) + ".sock"
        let (client, statuses, _) = makeClient(path, timing: .fast.reconnecting { _ in nil })
        client.start()

        XCTAssertEqual(
            statuses.first(2),
            [.connectFailed(ConnectionStatus.socketPathTooLong(path)), .gaveUp]
        )
    }

    /// After `close` the daemon is hung up on and the client is silent: no
    /// status, no message, no reconnect.
    func testCloseEndsTheLinkForGood() throws {
        let daemon = try FakeDaemon()
        let (client, statuses, _) = makeClient(daemon.path)
        client.start()
        XCTAssertEqual(statuses.first(1), [.connected])

        client.close()
        XCTAssertTrue(daemon.sawEnd(), "the socket is still open")
        XCTAssertFalse(daemon.accepted(2, timeout: 0.3), "the client reconnected")
        XCTAssertEqual(statuses.all, [.connected])
    }

    /// What the daemon had already said when `close` was called, but the app
    /// had not yet been handed, never reaches it.
    func testNothingReadBeforeCloseIsDeliveredAfterIt() throws {
        let daemon = try FakeDaemon()
        let (client, statuses, inbox) = makeClient(daemon.path)
        delivery.suspend()
        do {
            defer { delivery.resume() }
            client.start()
            XCTAssertEqual(daemon.received(1).count, 1, "the client is reading")
            try daemon.push(.helloOK(v: 1))
            try daemon.push(.bell(termID: "t1"))
            daemon.drop()
            XCTAssertTrue(daemon.accepted(2), "the client read both frames, then the hang-up, and is back")
            client.close()
        }
        delivery.sync {}

        XCTAssertEqual(inbox.all, [])
        XCTAssertEqual(statuses.all, [])
    }

    /// A daemon that has stopped reading cannot hold up the app's exit: a
    /// request stuck in its write is given a moment, then left behind.
    func testCloseDoesNotWaitForADaemonThatStoppedReading() throws {
        let daemon = try FakeDaemon()
        daemon.stopReading(after: 2)
        let (client, _, _) = makeClient(daemon.path)
        client.start()
        try daemon.push(.helloOK(v: 1))
        client.boardCreate()
        XCTAssertEqual(daemon.received(2).count, 2, "the link is up")
        client.send(megabyte)

        let returned = expectation(description: "close returned")
        DispatchQueue.global().async {
            client.close()
            returned.fulfill()
        }
        wait(for: [returned], timeout: 2)
        daemon.closeWedged()
    }

    /// A closed client has no link to flush to, ever: a request is dropped
    /// rather than queued.
    func testRequestsMadeAfterCloseAreDropped() {
        let (client, _, _) = makeClient(FakeDaemon.temporaryPath())
        client.close()

        assertRequestsAreDropped(by: client)
    }

    /// A client that gave up has no link to flush to either, and the app goes
    /// on making requests of it: each is dropped, not queued for good.
    func testRequestsMadeAfterGivingUpAreDropped() {
        let (client, statuses, _) = makeClient(
            FakeDaemon.temporaryPath(), timing: .fast.givingUpConnectAfter(0.05).reconnecting { _ in nil }
        )
        client.start()
        XCTAssertTrue(statuses.saw { $0 == .gaveUp })

        assertRequestsAreDropped(by: client)
    }

    /// Requests made just before `close` — the layout flushed on quit — are
    /// written before the link goes.
    func testRequestsMadeBeforeCloseAreStillWritten() throws {
        let daemon = try FakeDaemon()
        let (client, _, _) = makeClient(daemon.path)
        client.start()
        try daemon.push(.helloOK(v: 1))
        client.boardCreate()
        XCTAssertEqual(daemon.received(2).count, 2, "the link is up")

        let closes = (0..<200).map { Message.docClose(path: "/\($0).md") }
        closes.forEach(client.send)
        client.close()

        XCTAssertEqual(try messages(Array(daemon.received(202).dropFirst(2))), closes)
    }

    // MARK: - Where the socket is

    /// The channel picks the default socket; `TARMAC_SOCKET` overrides it, and
    /// an explicit path overrides both.
    func testTheSocketPathFollowsTheChannelUnlessOverridden() {
        let home = ["HOME": "/h"]
        XCTAssertEqual(
            DaemonClient(channel: .dev, environment: home).socketPath,
            "/h/Library/Application Support/tarmac/dev/tarmacd.sock"
        )
        XCTAssertEqual(
            DaemonClient(channel: .release, environment: home).socketPath,
            "/h/Library/Application Support/tarmac/tarmacd.sock"
        )
        let pinned = ["HOME": "/h", "TARMAC_SOCKET": "/repo/.dev/tarmacd.sock"]
        XCTAssertEqual(DaemonClient(channel: .dev, environment: pinned).socketPath, "/repo/.dev/tarmacd.sock")
        XCTAssertEqual(DaemonClient(socketPath: "/x.sock", channel: .dev, environment: pinned).socketPath, "/x.sock")
    }

    // MARK: - Spawning the daemon

    /// A connect miss launches `TARMAC_DAEMON`: once, in its own session, with
    /// its directory leading `PATH` and both streams in `tarmacd.log` beside
    /// the socket.
    func testAConnectMissSpawnsTheDaemonDetachedWithItsPathAndLog() throws {
        let fake = try ScriptedDaemon()
        defer { fake.remove() }
        let daemon = try fake.install(replying: .helloOK(v: 1))
        let (client, statuses, _) = makeClient(environment: fake.environment(daemon: daemon))
        client.start()

        XCTAssertEqual(statuses.first(1), [.connected])
        XCTAssertEqual(fake.launches, 1)
        XCTAssertEqual(fake.text("path"), "\(fake.dir):/usr/bin:/bin\n")
        XCTAssertTrue(eventually { fake.text("tarmacd.log") == "started\noops\n" }, fake.text("tarmacd.log"))
        let pid = pid_t(try XCTUnwrap(client.spawnedDaemonPid))
        XCTAssertEqual(getsid(pid), pid)
    }

    /// With a daemon already listening, nothing is spawned.
    func testAConnectThatSucceedsSpawnsNothing() throws {
        let fake = try ScriptedDaemon()
        defer { fake.remove() }
        let daemon = try fake.install(replying: .helloOK(v: 1))
        let listening = try FakeDaemon(path: fake.socket)
        let (client, statuses, _) = makeClient(environment: fake.environment(daemon: daemon))
        client.start()

        XCTAssertEqual(statuses.first(1), [.connected])
        XCTAssertTrue(listening.accepted(1))
        XCTAssertEqual(fake.launches, 0)
        XCTAssertNil(client.spawnedDaemonPid)
    }

    /// Without `TARMAC_DAEMON`, the `tarmacd` beside the app's own executable.
    func testTheDaemonBesideTheExecutableIsSpawned() throws {
        let fake = try ScriptedDaemon()
        defer { fake.remove() }
        try fake.install(named: "tarmacd", replying: .helloOK(v: 1))
        let (client, statuses, _) = makeClient(environment: fake.environment(), executableDir: fake.dir)
        client.start()

        XCTAssertEqual(statuses.first(1), [.connected])
        XCTAssertEqual(fake.launches, 1)
    }

    /// A daemon that was started but is not listening yet is waited for, never
    /// joined by a second one; once it has died, the next pass starts another.
    func testALiveChildBlocksASecondSpawnAndADeadOneDoesNot() throws {
        let fake = try ScriptedDaemon()
        defer { fake.remove() }
        let daemon = try fake.install(body: "sleep 2")
        let (client, statuses, _) = makeClient(
            environment: fake.environment(daemon: daemon), timing: .fast.givingUpConnectAfter(0.1)
        )
        client.start()

        XCTAssertTrue(eventually { fake.launches == 1 })
        let passes = statuses.all.count
        XCTAssertEqual(statuses.first(passes + 2).count, passes + 2, "two more connect passes ran while the child slept")
        XCTAssertEqual(fake.launches, 1)
        XCTAssertTrue(eventually(timeout: 5) { fake.launches >= 2 }, "the dead child was never replaced")
    }

    /// A launch that produced no child does not count as a daemon started: the
    /// next pass tries again.
    func testAFailedSpawnDoesNotLatch() throws {
        let fake = try ScriptedDaemon()
        defer { fake.remove() }
        let daemon = fake.dir + "/fake-tarmacd"
        let (client, statuses, _) = makeClient(
            environment: fake.environment(daemon: daemon), timing: .fast.givingUpConnectAfter(0.1)
        )
        client.start()
        XCTAssertEqual(statuses.first(1), [.connectFailed("no daemon at \(fake.socket)")])

        try fake.install(replying: .helloOK(v: 1))
        XCTAssertTrue(statuses.saw { $0 == .connected })
        XCTAssertEqual(fake.launches, 1)
    }

    // MARK: - Stale-daemon restart

    /// A daemon of another version is told to exit by the pid it reported, and
    /// the app reconnects at once — not on the backoff. That happens once: the
    /// next daemon is kept whatever it reports, and names the replacement.
    func testAStaleDaemonIsTerminatedOnceAndTheAppReconnectsAtOnce() throws {
        let daemon = try FakeDaemon()
        let stale = try victim()
        let bystander = try victim()
        let (client, statuses, inbox) = makeClient(
            daemon.path, appVersion: "0.2.0", timing: .fast.reconnecting { _ in nil }
        )
        client.boardCreate()
        client.start()

        try daemon.push(.helloOK(v: 1, daemonVersion: "0.1.0", daemonPid: Int(stale)))
        XCTAssertEqual(signalThatKilled(stale), SIGTERM)
        XCTAssertEqual(client.daemonReplaced, DaemonLaunch.Replaced(from: "0.1.0", to: nil))

        try daemon.push(.helloOK(v: 1, daemonVersion: "0.1.5", daemonPid: Int(bystander)), on: 1)
        XCTAssertEqual(statuses.first(3), [.connected, .restarting, .connected])
        XCTAssertEqual(inbox.first(1), [.helloOK(v: 1, daemonVersion: "0.1.5", daemonPid: Int(bystander))])
        XCTAssertEqual(client.daemonReplaced, DaemonLaunch.Replaced(from: "0.1.0", to: "0.1.5"))
        XCTAssertEqual(
            try messages(daemon.received(2, timeout: 0.2)), [.hello(role: "app", v: 1, appVersion: "0.2.0")],
            "the stale daemon is sent nothing but hello"
        )
        XCTAssertEqual(
            try messages(daemon.received(2, on: 1)),
            [.hello(role: "app", v: 1, appVersion: "0.2.0"), .boardCreate]
        )
        usleep(200_000)
        XCTAssertNil(signalThatKilled(bystander, timeout: 0), "a second mismatch proceeds")
        XCTAssertEqual(inbox.all.count, 1, "the stale daemon's hello_ok never reaches the app")
    }

    /// The reconnect waits for the dying daemon to remove its socket, so the
    /// new one does not find a live daemon and quit — but only until it is gone.
    func testTheRestartWaitsForTheSocketFileToDisappear() throws {
        let daemon = try FakeDaemon()
        let stale = try victim()
        var timing = DaemonClient.Timing.fast
        timing.restartWaitBudget = 10
        let (client, statuses, _) = makeClient(daemon.path, appVersion: "0.2.0", timing: timing)
        client.start()

        try daemon.push(.helloOK(v: 1, daemonVersion: "0.1.0", daemonPid: Int(stale)))
        XCTAssertEqual(signalThatKilled(stale), SIGTERM)
        usleep(300_000)
        XCTAssertEqual(daemon.connectionCount, 1, "no reconnect while the socket file exists")

        let gone = Date()
        daemon.shutDown()
        // Longer than a poll, so the client sees the path empty before it is taken again.
        usleep(200_000)
        let next = try FakeDaemon(path: daemon.path)
        XCTAssertTrue(next.accepted(1))
        XCTAssertLessThan(Date().timeIntervalSince(gone), 3, "the wait ends when the file does")
        XCTAssertEqual(statuses.first(3), [.connected, .restarting, .connected])
    }

    /// A daemon too old to report a pid is the child this app spawned; with it
    /// gone the app may spawn again, and does.
    func testAStaleDaemonWithoutAPidIsTheSpawnedChild() throws {
        let fake = try ScriptedDaemon()
        defer { fake.remove() }
        let daemon = try fake.install(replying: .helloOK(v: 1))
        let (client, statuses, inbox) = makeClient(
            appVersion: "0.2.0", environment: fake.environment(daemon: daemon),
            timing: .fast.reconnecting { _ in nil }
        )
        client.start()

        XCTAssertEqual(statuses.first(3), [.connected, .restarting, .connected])
        XCTAssertEqual(fake.launches, 2)
        XCTAssertEqual(inbox.first(1), [.helloOK(v: 1)])
        XCTAssertEqual(client.daemonReplaced, DaemonLaunch.Replaced(from: nil, to: nil))
    }

    /// A daemon of the app's own version is left alone.
    func testAMatchingDaemonIsKept() throws {
        let daemon = try FakeDaemon()
        let running = try victim()
        let (client, statuses, inbox) = makeClient(daemon.path, appVersion: "0.2.0")
        client.start()

        let helloOK = Message.helloOK(v: 1, daemonVersion: "0.2.0", daemonPid: Int(running))
        try daemon.push(helloOK)
        XCTAssertEqual(inbox.first(1), [helloOK])
        XCTAssertEqual(statuses.all, [.connected])
        XCTAssertNil(client.daemonReplaced)
        XCTAssertNil(signalThatKilled(running, timeout: 0.2))
    }

    /// An app that names no version cannot call a daemon stale.
    func testAnAppWithoutAVersionRestartsNothing() throws {
        let daemon = try FakeDaemon()
        let running = try victim()
        let (client, statuses, inbox) = makeClient(daemon.path)
        client.start()

        let helloOK = Message.helloOK(v: 1, daemonVersion: "0.1.0", daemonPid: Int(running))
        try daemon.push(helloOK)
        XCTAssertEqual(inbox.first(1), [helloOK])
        XCTAssertEqual(statuses.all, [.connected])
        XCTAssertNil(signalThatKilled(running, timeout: 0.2))
    }
}
