import XCTest
@testable import TarmacKit

/// The QA driver's socket (spec 2609.0015, #166; parity rows Q3–Q5): how the
/// app claims it, and the one request each connection carries. The claim rules
/// are `desktop/src-tauri/src/dev_driver.rs`'s S66–S69, against a real socket.
final class DevSocketTests: XCTestCase {
    private var directory = ""

    override func setUp() {
        // Short on purpose: a socket path must fit `sockaddr_un`.
        directory = NSTemporaryDirectory() + "dv-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func claimed(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> DevSocket {
        switch DevSocket.claim(path: path) {
        case .success(let socket): return socket
        case .failure(let failure):
            XCTFail("claim failed: \(failure)", file: file, line: line)
            throw failure
        }
    }

    private func failure(_ path: String) -> DevSocket.ClaimFailure? {
        guard case .failure(let failure) = DevSocket.claim(path: path) else { return nil }
        return failure
    }

    // MARK: - claiming

    func testS66ClaimingCreatesAPrivateSocketAndItsParent() throws {
        let path = directory + "/nested/tarmac-dev.sock"
        let socket = try claimed(path)
        defer { socket.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSocket)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testS67AStaleSocketFileIsReplaced() throws {
        let path = directory + "/tarmac-dev.sock"
        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: path))
        let socket = try claimed(path)
        defer { socket.close() }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType, .typeSocket)
    }

    /// The daemon's rule here is to exit 1; the app must not, because losing a
    /// window over a dev-only endpoint is worse than not having the endpoint.
    func testS67ALiveSiblingsSocketIsLeftAlone() throws {
        let path = directory + "/tarmac-dev.sock"
        let sibling = try claimed(path)
        defer { sibling.close() }
        XCTAssertEqual(failure(path), .liveOwner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "unlinked a live sibling's socket")
        let probe = try XCTUnwrap(DaemonSocket.connect(to: path), "the sibling stopped answering")
        Darwin.close(probe)
    }

    func testS68TheSocketIsRemovedOnClose() throws {
        let path = directory + "/tarmac-dev.sock"
        let socket = try claimed(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        socket.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the socket file outlived the listener")
        XCTAssertEqual(socket.accept(), .closed)
    }

    /// The path, and very likely the descriptor number, belong to whoever
    /// claimed next: a repeated close must touch neither.
    func testASecondCloseLeavesASuccessorAlone() throws {
        let path = directory + "/tarmac-dev.sock"
        let first = try claimed(path)
        first.close()
        let second = try claimed(path)
        defer { second.close() }
        first.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "a repeated close unlinked the successor's socket")
        let probe = try XCTUnwrap(DaemonSocket.connect(to: path), "a repeated close closed the successor's listener")
        Darwin.close(probe)
    }

    /// Copied into a `sockaddr_un`, a longer path would be truncated into some
    /// other path.
    func testAPathTooLongForASocketAddressIsRefused() {
        let path = directory + "/" + String(repeating: "x", count: 104) + ".sock"
        XCTAssertEqual(failure(path), .pathTooLong)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - one request per connection

    private func exchange(
        _ send: (Int32) -> Void, answer: (DevRequest) -> DevReply = { _ in DevReply(ok: true, body: "{}") }
    ) throws -> (reply: DevReply?, closed: Bool) {
        let path = directory + "/tarmac-dev.sock"
        let socket = try claimed(path)
        defer { socket.close() }
        let client = try XCTUnwrap(DaemonSocket.connect(to: path))
        defer { Darwin.close(client) }
        send(client)
        DevSocket.serve(try connection(to: socket), answer: answer)
        let reply = try DaemonSocket.readFrame(from: client).map(DevReply.decode(payload:))
        return (reply, DaemonSocket.readFrame(from: client) == nil)
    }

    private func connection(to socket: DevSocket, file: StaticString = #filePath, line: UInt = #line) throws -> Int32 {
        guard case .connection(let connection) = socket.accept() else {
            XCTFail("nothing was accepted", file: file, line: line)
            throw POSIXError(.ECONNABORTED)
        }
        return connection
    }

    /// The CLI gives up a second after the app's own bound, so a reply can be
    /// written to a caller that has hung up. That write must fail, not raise
    /// SIGPIPE, which would end the app; the megabyte is what makes the write
    /// outlast the socket's buffer.
    func testAReplyToACallerThatHungUpDoesNotEndTheProcess() throws {
        let path = directory + "/tarmac-dev.sock"
        let socket = try claimed(path)
        defer { socket.close() }
        let client = try XCTUnwrap(DaemonSocket.connect(to: path))
        write(.zoom(z: 1), to: client)
        let connection = try connection(to: socket)
        Darwin.close(client)
        DevSocket.serve(connection) { _ in DevReply(ok: true, body: String(repeating: "x", count: 1 << 20)) }
    }

    private func write(_ request: DevRequest, to client: Int32) {
        XCTAssertTrue(DaemonSocket.write(try! Framing.frame(request.encodedPayload()), to: client))
    }

    func testARequestIsAnsweredAndTheConnectionCloses() throws {
        var seen: [DevRequest] = []
        let result = try exchange({ write(.zoom(z: 0.5), to: $0) }, answer: { request in
            seen.append(request)
            return DevReply(ok: true, body: #"{"zoom":0.5}"#)
        })
        XCTAssertEqual(seen, [.zoom(z: 0.5)])
        XCTAssertEqual(result.reply, DevReply(ok: true, body: #"{"zoom":0.5}"#))
        XCTAssertTrue(result.closed)
    }

    /// A peer that connects and closes without a frame is the liveness probe a
    /// sibling's claim makes; answering or logging it would make every probe
    /// noisy.
    func testS69AnEmptyConnectionIsDroppedSilently() throws {
        var asked = false
        let result = try exchange({ shutdown($0, SHUT_WR) }, answer: { _ in
            asked = true
            return DevReply(ok: true, body: "{}")
        })
        XCTAssertFalse(asked)
        XCTAssertNil(result.reply)
    }

    func testS69AnOversizedFrameClosesTheConnection() throws {
        var asked = false
        let result = try exchange({ client in
            XCTAssertTrue(DaemonSocket.write(Data([0xFF, 0xFF, 0xFF, 0xFF]), to: client))
        }, answer: { _ in
            asked = true
            return DevReply(ok: true, body: "{}")
        })
        XCTAssertFalse(asked)
        XCTAssertNil(result.reply)
    }

    func testAnUndecodableFrameIsABadRequest() throws {
        var asked = false
        let result = try exchange({ client in
            XCTAssertTrue(DaemonSocket.write(try! Framing.frame(Data([0xC1])), to: client))
        }, answer: { _ in
            asked = true
            return DevReply(ok: true, body: "{}")
        })
        XCTAssertFalse(asked)
        let reply = try XCTUnwrap(result.reply)
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.body.contains(#""error":"bad_request""#), reply.body)
    }

    /// A map with no usable `t` is as undecodable as bytes that are not msgpack.
    func testAFrameWithoutAVerbIsABadRequest() throws {
        let payload = MsgPack.encode(.orderedMap([MsgPackField("card", .string("t-1"))]))
        let result = try exchange({ client in
            XCTAssertTrue(DaemonSocket.write(try! Framing.frame(payload), to: client))
        })
        XCTAssertTrue(try XCTUnwrap(result.reply).body.contains(#""error":"bad_request""#))
    }
}
