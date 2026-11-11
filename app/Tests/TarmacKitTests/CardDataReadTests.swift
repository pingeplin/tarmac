import XCTest
@testable import TarmacKit

/// The read of a card's data file (spec 2611.0002 S30, S32), with a stand-in
/// file system: where each path resolves to, and what each resolved path
/// holds.
final class CardDataReadTests: XCTestCase {
    private struct Missing: LocalizedError {
        var errorDescription: String? { "No such file or directory (os error 2)" }
    }

    private let html = "/a/b/dash.html"
    private let file = "/a/b/stats.json"

    /// `links` maps a path to where it resolves; a path not in it resolves
    /// to itself, and one mapped to nil does not resolve.
    private final class Disk {
        var links: [String: String?] = [:]
        var files: [String: Result<Data, any Error>] = [:]
        var reads: [String] = []

        func resolve(_ path: String) -> Result<String, any Error> {
            guard let link = links[path] else { return .success(path) }
            return link.map { .success($0) } ?? .failure(Missing())
        }

        func read(_ path: String) -> Result<Data, any Error> {
            reads.append(path)
            return files[path] ?? .failure(Missing())
        }
    }

    private func read(_ disk: Disk) -> CardDataRead.Outcome {
        CardDataRead.read(file: file, html: html, resolve: disk.resolve, read: disk.read)
    }

    private func holding(_ bytes: [UInt8]) -> Disk {
        let disk = Disk()
        disk.files[file] = .success(Data(bytes))
        return disk
    }

    private func holding(_ text: String) -> Disk { holding(Array(text.utf8)) }

    func testS30AFileBesideTheCardIsReadAsText() {
        let disk = holding(#"{"n":1}"#)
        XCTAssertEqual(read(disk), .text(#"{"n":1}"#))
        XCTAssertEqual(disk.reads, [file])
    }

    func testS30ANameThatResolvesToAnotherDirectoryIsNeverRead() {
        let disk = holding("{}")
        disk.links[file] = "/etc/stats.json"
        disk.files["/etc/stats.json"] = .success(Data("{}".utf8))
        guard case .refused(let reason) = read(disk) else { return XCTFail("read") }
        XCTAssertTrue(reason.contains("outside"), reason)
        XCTAssertEqual(disk.reads, [])

        disk.links[file] = "/a/b/sub/stats.json"
        guard case .refused = read(disk) else { return XCTFail("a subdirectory was read") }
        XCTAssertEqual(disk.reads, [])
    }

    /// The resolved file is the one read, never the name.
    func testS30ANameThatResolvesToAnotherFileBesideTheCardReadsThatFile() {
        let disk = Disk()
        disk.links[file] = "/a/b/real.json"
        disk.files["/a/b/real.json"] = .success(Data("[1]".utf8))
        XCTAssertEqual(read(disk), .text("[1]"))
        XCTAssertEqual(disk.reads, ["/a/b/real.json"])
    }

    /// The directory is the resolved HTML file's, not its name's.
    func testS30TheDirectoryIsTheResolvedHTMLFiles() {
        let disk = holding("{}")
        disk.links[html] = "/c/dash.html"
        guard case .refused = read(disk) else { return XCTFail("read beside the HTML file's name") }
        disk.links[file] = "/c/stats.json"
        disk.files["/c/stats.json"] = .success(Data("{}".utf8))
        XCTAssertEqual(read(disk), .text("{}"))
        XCTAssertEqual(disk.reads, ["/c/stats.json"])
    }

    func testS30AResolveThatFailsForEitherFileIsARefusalAndNoRead() {
        for path in [file, html] {
            let disk = holding("{}")
            disk.links[path] = .some(nil)
            guard case .refused(let reason) = read(disk) else { return XCTFail(path) }
            XCTAssertTrue(reason.contains("No such file"), reason)
            XCTAssertEqual(disk.reads, [], path)
        }
    }

    func testS30AReadThatFailsGivesItsReason() {
        for error in [FileBytes.NotAFile(), FileBytes.TooLarge(limit: FileBytes.sizeCap)] as [any Error] {
            let disk = Disk()
            disk.files[file] = .failure(error)
            XCTAssertEqual(read(disk), .refused(error.localizedDescription))
        }
    }

    // MARK: - the bytes (S32)

    func testS32BytesThatAreNotUTF8AreRefused() {
        XCTAssertEqual(read(holding([0x22, 0xff, 0x22])), .refused(CardDataRead.notUTF8))
    }

    func testS32NestingIsTakenTo127LevelsAndNoDeeper() {
        let nested = { (depth: Int) in String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }
        XCTAssertEqual(read(holding(nested(127))), .text(nested(127)))
        XCTAssertEqual(read(holding(nested(128))), .refused(CardDataRead.notJSON))
    }

    func testS32AnyValueIsTakenAtTheTopWithWhiteSpaceAround() {
        for text in ["3", #""x""#, "null", " \n\t{\"a\":[1,2]}\r\n "] {
            XCTAssertEqual(read(holding(text)), .text(text), text)
        }
    }

    func testS32WhatStrictJSONRefusesIsRefused() {
        for bytes in [[], [0xef, 0xbb, 0xbf] + Array("{}".utf8), Array("1e400".utf8), Array(#""\ud800""#.utf8)] {
            XCTAssertEqual(read(holding(bytes)), .refused(CardDataRead.notJSON), "\(bytes)")
        }
    }
}
