import XCTest
import TarmacKit

/// Where the sample log goes and how it is kept from growing (spec 2611.0004),
/// in a real temporary directory.
final class SampleLogFileTests: XCTestCase {
    private var dir = ""
    private var log: String { dir + "/tarmac-app.jsonl" }
    private var rotated: String { log + ".1" }
    private let cap = 16

    override func setUp() {
        dir = NSTemporaryDirectory() + "tarmac-samplelog-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func text(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func write(_ body: String, to path: String) throws {
        try Data(body.utf8).write(to: URL(fileURLWithPath: path))
    }

    func testS12AppendsMakeTheFileAndAddALineEach() {
        SampleLogFile.append("one", to: log, cap: cap)
        XCTAssertEqual(text(log), "one\n")
        SampleLogFile.append("two", to: log, cap: cap)
        XCTAssertEqual(text(log), "one\ntwo\n")
    }

    func testS13AFileOverTheCapMovesToDot1AndTheFileStartsAnew() throws {
        let old = String(repeating: "x", count: cap + 1)
        try write(old, to: log)
        SampleLogFile.append("new", to: log, cap: cap)
        XCTAssertEqual(text(rotated), old)
        XCTAssertEqual(text(log), "new\n")
    }

    func testS14AFileOfExactlyTheCapIsNotMoved() throws {
        let old = String(repeating: "x", count: cap)
        try write(old, to: log)
        SampleLogFile.append("new", to: log, cap: cap)
        XCTAssertNil(text(rotated))
        XCTAssertEqual(text(log), old + "new\n")
    }

    func testS15ANewerOldContentReplacesDot1() throws {
        try write("older", to: rotated)
        let newer = String(repeating: "y", count: cap + 1)
        try write(newer, to: log)
        SampleLogFile.append("new", to: log, cap: cap)
        XCTAssertEqual(text(rotated), newer)
        XCTAssertEqual(text(log), "new\n")
    }

    func testS16ADirectoryThatDoesNotExistGetsNoFile() {
        let missing = dir + "/missing"
        SampleLogFile.append("one", to: missing + "/tarmac-app.jsonl", cap: cap)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    /// `<path>.1` is a directory with something in it, so the move fails.
    func testAFailedMoveDropsTheLineAndLeavesTheFile() throws {
        try FileManager.default.createDirectory(atPath: rotated, withIntermediateDirectories: true)
        try write("x", to: rotated + "/keep")
        let old = String(repeating: "x", count: cap + 1)
        try write(old, to: log)
        SampleLogFile.append("new", to: log, cap: cap)
        XCTAssertEqual(text(log), old)
    }

    func testS17TheFileIsBesideTheSocket() {
        XCTAssertEqual(SampleLogFile.path(socketPath: "/x/y/tarmacd.sock"), "/x/y/tarmac-app.jsonl")
    }

    func testTheDefaultCapIs1MiB() {
        XCTAssertEqual(SampleLogFile.cap, 1 << 20)
    }
}
