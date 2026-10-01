import XCTest
import TarmacKit

/// A one-connection stand-in for `tarmacd`: binds a real Unix socket, records
/// every frame the client writes, and can push frames back. It is what lets the
/// client's wiring be tested end to end without a daemon binary.
private final class FakeDaemon: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let state = NSCondition()
    private var connection: Int32 = -1
    private var frames: [Data] = []

    init() throws {
        path = NSTemporaryDirectory() + "td-\(UUID().uuidString.prefix(8)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                precondition(strlen(src) < dst.count, "temp socket path too long")
                memcpy(dst.baseAddress!, src, strlen(src) + 1)
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Thread.detachNewThread { [self] in serve() }
    }

    deinit {
        state.lock()
        let fd = connection
        state.unlock()
        if fd >= 0 { close(fd) }
        close(listener)
        unlink(path)
    }

    private func serve() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        state.lock()
        connection = fd
        state.broadcast()
        state.unlock()

        var decoder = Framing.StreamDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return }
            decoder.append(Data(buffer[..<n]))
            while let frame = try? decoder.nextFrame() {
                state.lock()
                frames.append(frame)
                state.broadcast()
                state.unlock()
            }
        }
    }

    /// The first `count` payloads received, waiting up to `timeout` for them.
    /// Returns what arrived, so a short read fails the caller's assertion.
    func received(_ count: Int, timeout: TimeInterval = 2) -> [Data] {
        let deadline = Date().addingTimeInterval(timeout)
        state.lock()
        defer { state.unlock() }
        while frames.count < count, state.wait(until: deadline) {}
        return Array(frames.prefix(count))
    }

    func push(_ message: Message) throws {
        let framed = try Framing.frame(message.encodedPayload())
        let deadline = Date().addingTimeInterval(2)
        state.lock()
        while connection < 0, state.wait(until: deadline) {}
        let fd = connection
        state.unlock()
        try framed.withUnsafeBytes { raw in
            guard write(fd, raw.baseAddress, raw.count) == raw.count else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}

/// The client's wiring against a real socket: what `connect` says first, what
/// each send helper puts on the wire, and what reaches `onMessage`.
final class DaemonClientTests: XCTestCase {
    private let delivery = DispatchQueue(label: "tarmac.test.delivery")

    private func messages(_ payloads: [Data]) throws -> [Message] {
        try payloads.map { try Message.decode(payload: $0) }
    }

    /// 2609.0012: the app names its version in `hello`; it is the only source of
    /// the app version `tarmac --version` reports.
    func testHelloNamesTheAppVersion() throws {
        let daemon = try FakeDaemon()
        let client = DaemonClient(socketPath: daemon.path, appVersion: "9.9.9", deliveryQueue: delivery)
        try client.connect()
        defer { client.close() }

        XCTAssertEqual(try messages(daemon.received(1)), [.hello(role: "app", v: 1, appVersion: "9.9.9")])
    }

    /// A client that names no version sends conformance vector 2, byte for byte.
    func testHelloWithoutAVersionIsVector2() throws {
        let daemon = try FakeDaemon()
        let client = DaemonClient(socketPath: daemon.path, deliveryQueue: delivery)
        try client.connect()
        defer { client.close() }

        XCTAssertEqual(
            daemon.received(1),
            [hexData("83 a1 74 a5 68 65 6c 6c 6f a4 72 6f 6c 65 a3 61 70 70 a1 76 01")]
        )
    }

    /// One helper per app → daemon message, each writing exactly its frame, in
    /// the order sent.
    func testEverySendHelperWritesItsFrame() throws {
        let daemon = try FakeDaemon()
        let client = DaemonClient(socketPath: daemon.path, deliveryQueue: delivery)
        try client.connect()
        defer { client.close() }

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

    /// `hello_ok` reaches the app with the daemon's version and pid — the two
    /// facts `DaemonLaunch.shouldRestart` / `restartTarget` are fed.
    func testHelloOKReachesTheAppWithTheDaemonsVersionAndPid() throws {
        let daemon = try FakeDaemon()
        let client = DaemonClient(socketPath: daemon.path, appVersion: "0.13.1", deliveryQueue: delivery)
        let delivered = expectation(description: "hello_ok delivered")
        let inbox = Inbox()
        client.onMessage = { message in
            inbox.set(message)
            delivered.fulfill()
        }
        try client.connect()
        defer { client.close() }

        try daemon.push(.helloOK(v: 1, daemonVersion: "0.13.0", daemonPid: 4242))
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(inbox.message, .helloOK(v: 1, daemonVersion: "0.13.0", daemonPid: 4242))
    }
}

private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Message?

    var message: Message? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ message: Message) {
        lock.lock()
        stored = message
        lock.unlock()
    }
}
