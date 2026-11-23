import XCTest

@testable import TarmacKit

/// Blocking I/O on a Unix stream socket: connect, one length-prefixed frame in,
/// bytes out. Each test owns its descriptors: a socket pair, or a listener in
/// its own temporary directory.
final class DaemonSocketTests: XCTestCase {
    private var directory = ""
    private var descriptors: [Int32] = []

    override func setUp() {
        // Short on purpose: a socket path must fit `sockaddr_un`.
        directory = NSTemporaryDirectory() + "ds-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for fd in descriptors { close(fd) }
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// Two connected ends that report a write to a closed peer as a failure, not SIGPIPE.
    private func pair() throws -> (Int32, Int32) {
        var made: [Int32] = [-1, -1]
        let fds = try XCTUnwrap(socketpair(AF_UNIX, SOCK_STREAM, 0, &made) == 0 ? made : nil, "socketpair")
        var yes: Int32 = 1
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        }
        descriptors += fds
        return (fds[0], fds[1])
    }

    private func listener(at path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        descriptors.append(fd)
        var addr = DaemonSocket.address(of: path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "bind")
        XCTAssertEqual(listen(fd, 1), 0, "listen")
        return fd
    }

    private func header(_ length: UInt32) -> Data { withUnsafeBytes(of: length.bigEndian) { Data($0) } }

    private func closeEnd(_ fd: Int32) {
        close(fd)
        descriptors.removeAll { $0 == fd }
    }

    // MARK: - connect

    func testConnectReachesAListenerAtThePath() throws {
        let path = directory + "/s.sock"
        let server = listener(at: path)
        let client = try XCTUnwrap(DaemonSocket.connect(to: path))
        descriptors.append(client)
        let accepted = accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        descriptors.append(accepted)
        XCTAssertTrue(DaemonSocket.write(Data("hi".utf8), to: client))
        var buffer = [UInt8](repeating: 0, count: 2)
        XCTAssertEqual(read(accepted, &buffer, 2), 2)
        XCTAssertEqual(buffer, Array("hi".utf8))
    }

    func testConnectIsNilWhenNothingListens() {
        XCTAssertNil(DaemonSocket.connect(to: directory + "/none.sock"))
    }

    /// A write to a peer that has gone is a failure the caller sees, not a signal
    /// that ends the app.
    func testAConnectedDescriptorReportsAGonePeerAsAFailedWrite() throws {
        let path = directory + "/s.sock"
        let server = listener(at: path)
        let client = try XCTUnwrap(DaemonSocket.connect(to: path))
        descriptors.append(client)
        let accepted = accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        close(accepted)
        XCTAssertTrue(DaemonSocket.waitReadable(client, within: 5))
        XCTAssertFalse(DaemonSocket.write(Data(count: 1 << 20), to: client))
    }

    // MARK: - address

    func testTheAddressIsAUnixFamilyWithThePath() {
        let path = directory + "/s.sock"
        var addr = DaemonSocket.address(of: path)
        XCTAssertEqual(addr.sun_family, sa_family_t(AF_UNIX))
        let bytes = withUnsafeBytes(of: &addr.sun_path) { Array($0) }
        XCTAssertEqual(Array(bytes.prefix(path.utf8.count)), Array(path.utf8))
    }

    // MARK: - readFrame

    func testAFrameIsABigEndianLengthAndThatManyBytes() throws {
        let (reader, writer) = try pair()
        let payload = Data((0..<258).map { UInt8($0 % 251) })
        XCTAssertTrue(DaemonSocket.write(header(258) + payload, to: writer))
        XCTAssertEqual(DaemonSocket.readFrame(from: reader), payload)
    }

    func testFramesBackToBackAreReadOneAtATimeAndAnEmptyOneIsEmpty() throws {
        let (reader, writer) = try pair()
        XCTAssertTrue(
            DaemonSocket.write(header(2) + Data("ab".utf8) + header(0) + header(1) + Data("c".utf8), to: writer))
        XCTAssertEqual(DaemonSocket.readFrame(from: reader), Data("ab".utf8))
        XCTAssertEqual(DaemonSocket.readFrame(from: reader), Data())
        XCTAssertEqual(DaemonSocket.readFrame(from: reader), Data("c".utf8))
    }

    func testTheEndOfTheStreamInsideTheHeaderOrThePayloadIsNoFrame() throws {
        let (headerReader, headerWriter) = try pair()
        XCTAssertTrue(DaemonSocket.write(Data([0, 0]), to: headerWriter))
        closeEnd(headerWriter)
        XCTAssertNil(DaemonSocket.readFrame(from: headerReader))

        let (payloadReader, payloadWriter) = try pair()
        XCTAssertTrue(DaemonSocket.write(header(3) + Data("ab".utf8), to: payloadWriter))
        closeEnd(payloadWriter)
        XCTAssertNil(DaemonSocket.readFrame(from: payloadReader))
    }

    func testAFrameOfExactlyTheCapIsRead() throws {
        let (reader, writer) = try pair()
        let length = Framing.maxFrameLength
        let frame = header(UInt32(length)) + Data(count: length)
        let sent = expectation(description: "the writer is done")
        Thread.detachNewThread {
            _ = DaemonSocket.write(frame, to: writer)
            sent.fulfill()
        }
        XCTAssertEqual(DaemonSocket.readFrame(from: reader)?.count, length)
        closeEnd(reader)
        wait(for: [sent], timeout: 30)
    }

    /// The cap is checked before the payload is read: a full payload past it
    /// is still no frame.
    func testALengthPastTheCapIsNoFrameEvenWhenItsBytesFollow() throws {
        let (reader, writer) = try pair()
        let length = Framing.maxFrameLength + 1
        let frame = header(UInt32(length)) + Data(count: length)
        let sent = expectation(description: "the writer is done")
        Thread.detachNewThread {
            _ = DaemonSocket.write(frame, to: writer)
            sent.fulfill()
        }
        XCTAssertNil(DaemonSocket.readFrame(from: reader))
        closeEnd(reader)
        wait(for: [sent], timeout: 30)
    }

    // MARK: - waitReadable

    func testAnEmptyStreamIsNotReadable() throws {
        let (reader, _) = try pair()
        XCTAssertFalse(DaemonSocket.waitReadable(reader, within: 0))
    }

    func testQueuedBytesOrAnEndedStreamAreReadable() throws {
        let (reader, writer) = try pair()
        XCTAssertTrue(DaemonSocket.write(Data([1]), to: writer))
        XCTAssertTrue(DaemonSocket.waitReadable(reader, within: 5))

        let (endedReader, endedWriter) = try pair()
        closeEnd(endedWriter)
        XCTAssertTrue(DaemonSocket.waitReadable(endedReader, within: 5))
    }

    // MARK: - write

    func testAWriteToAClosedPeerFails() throws {
        let (reader, writer) = try pair()
        closeEnd(reader)
        XCTAssertFalse(DaemonSocket.write(Data([1]), to: writer))
    }
}
