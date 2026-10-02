import XCTest
@testable import TarmacKit

/// Reading a card's file as the Tauri backend's `std::fs::read` does: the path
/// as named, and an error that reads the way Rust's does.
final class FileBytesTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "tarmac-filebytes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
    }

    private func reason(_ result: Result<Data, any Error>) -> String? {
        if case .failure(let error) = result { return error.localizedDescription }
        return nil
    }

    func testReadsTheBytesOfAFile() throws {
        let path = directory + "/a.bin"
        let bytes = Data([0x00, 0xFF, 0x41, 0x0A])
        try bytes.write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(try FileBytes.read(path: path).get(), bytes)
    }

    func testReadsAFileLargerThanOneChunk() throws {
        let path = directory + "/big.bin"
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(try FileBytes.read(path: path).get(), bytes)
    }

    func testAnEmptyFileIsEmptyNotAnError() throws {
        let path = directory + "/empty"
        try Data().write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(try FileBytes.read(path: path).get(), Data())
    }

    func testAMissingFileReadsAsRustsError() {
        XCTAssertEqual(reason(FileBytes.read(path: directory + "/nope")), "No such file or directory (os error 2)")
    }

    func testADirectoryIsNotAFile() {
        XCTAssertEqual(reason(FileBytes.read(path: directory)), "Is a directory (os error 21)")
    }

    /// A trailing slash names a directory; `URL(fileURLWithPath:)` would drop it
    /// and read the file.
    func testATrailingSlashOnAFileIsNotThatFile() throws {
        let path = directory + "/a.txt"
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(reason(FileBytes.read(path: path + "/")), "Not a directory (os error 20)")
    }

    // MARK: - Only regular files

    /// A card names any path it likes, and can send itself to one. A device
    /// has no end to read to: `/dev/zero` would fill memory.
    func testADeviceIsNotRead() {
        XCTAssertEqual(reason(FileBytes.read(path: "/dev/null")), "not a regular file")
        XCTAssertEqual(reason(FileBytes.read(path: "/dev/zero")), "not a regular file")
    }

    /// A pipe with no writer blocks whoever opens it. It is refused at once.
    func testAPipeIsRefusedWithoutWaitingForAWriter() {
        let pipe = directory + "/pipe"
        XCTAssertEqual(mkfifo(pipe, 0o600), 0)
        let answered = expectation(description: "the read returned")
        let result = Locked<Result<Data, any Error>?>(nil)
        DispatchQueue.global().async {
            result.set(FileBytes.read(path: pipe))
            answered.fulfill()
        }
        let outcome = XCTWaiter().wait(for: [answered], timeout: 2)
        // A reader stuck on the open is let go, so the test leaves no thread behind.
        let writer = open(pipe, O_WRONLY | O_NONBLOCK)
        if writer >= 0 { close(writer) }

        XCTAssertEqual(outcome, .completed, "the read waited on the pipe")
        XCTAssertEqual(result.get().flatMap(reason), "not a regular file")
    }

    func testASymbolicLinkToAFileReadsThatFile() throws {
        let target = directory + "/target.txt"
        let link = directory + "/link.txt"
        try Data("through the link".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertEqual(try FileBytes.read(path: link).get(), Data("through the link".utf8))
    }

    // MARK: - The file a name leads to

    private func why(_ result: Result<String, any Error>) -> String? {
        if case .failure(let error) = result { return error.localizedDescription }
        return nil
    }

    func testASymbolicLinkResolvesToTheFileItLeadsTo() throws {
        let target = directory + "/id_rsa"
        let link = directory + "/logo.png"
        try Data("key".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "id_rsa")

        let file = try FileBytes.resolved(path: link).get()
        XCTAssertTrue(file.hasSuffix("/id_rsa"), file)
        XCTAssertEqual(file, try FileBytes.resolved(path: target).get())
    }

    func testLinksAreFollowedToTheEndThroughALinkedDirectory() throws {
        try FileManager.default.createDirectory(atPath: directory + "/real", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: directory + "/real/secret.txt"))
        try FileManager.default.createSymbolicLink(atPath: directory + "/real/second.png", withDestinationPath: "secret.txt")
        try FileManager.default.createSymbolicLink(atPath: directory + "/real/first.png", withDestinationPath: "second.png")
        try FileManager.default.createSymbolicLink(atPath: directory + "/assets", withDestinationPath: "real")

        let file = try FileBytes.resolved(path: directory + "/assets/first.png").get()
        XCTAssertTrue(file.hasSuffix("/real/secret.txt"), file)
    }

    func testANameThatLeadsNowhereFailsAsReadingItDoes() throws {
        try FileManager.default.createSymbolicLink(atPath: directory + "/dangling.png", withDestinationPath: "nope")
        try FileManager.default.createSymbolicLink(atPath: directory + "/loop.png", withDestinationPath: "loop.png")

        XCTAssertEqual(why(FileBytes.resolved(path: directory + "/nope.png")), "No such file or directory (os error 2)")
        XCTAssertEqual(why(FileBytes.resolved(path: directory + "/dangling.png")), "No such file or directory (os error 2)")
        XCTAssertEqual(why(FileBytes.resolved(path: directory + "/loop.png")), "Too many levels of symbolic links (os error 62)")
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func set(_ new: Value) {
        lock.lock()
        value = new
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
