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
}
