import XCTest
@testable import TarmacKit

/// The read of a card's data file (spec 2611.0002 S30, S32), with a stand-in
/// file system (`SchemeFixtures.Disk`): a path resolves when it, or the file
/// its link leads to, is on the disk.
final class CardDataReadTests: XCTestCase {
    private typealias Disk = SchemeFixtures.Disk

    private let html = "/a/b/dash.html"
    private let file = "/a/b/stats.json"
    private let missing = SchemeFixtures.NoSuchFile().localizedDescription

    private func read(_ disk: Disk) -> CardDataRead.Outcome {
        CardDataRead.read(file: file, html: html, resolve: disk.resolve, read: disk.read)
    }

    /// The card's file and its data file beside it, holding `bytes`.
    private func holding(_ bytes: [UInt8]) -> Disk {
        Disk([html: Data(), file: Data(bytes)])
    }

    private func holding(_ text: String) -> Disk { holding(Array(text.utf8)) }

    func testS30AFileBesideTheCardIsReadAsText() {
        let disk = holding(#"{"n":1}"#)
        XCTAssertEqual(read(disk), .text(#"{"n":1}"#))
        XCTAssertEqual(disk.opened, [file])
    }

    func testS30ANameThatResolvesToAnotherDirectoryIsNeverRead() {
        for target in ["/etc/stats.json", "/a/b/sub/stats.json"] {
            let disk = Disk([html: Data(), file: Data("{}".utf8), target: Data("{}".utf8)], links: [file: target])
            XCTAssertEqual(read(disk), .refused(CardDataRead.leadsOutside), target)
            XCTAssertEqual(disk.opened, [], target)
        }
    }

    /// The resolved file is the one read, never the name.
    func testS30ANameThatResolvesToAnotherFileBesideTheCardReadsThatFile() {
        let disk = Disk([html: Data(), "/a/b/real.json": Data("[1]".utf8)], links: [file: "/a/b/real.json"])
        XCTAssertEqual(read(disk), .text("[1]"))
        XCTAssertEqual(disk.opened, ["/a/b/real.json"])
    }

    /// The directory is the resolved HTML file's, not its name's.
    func testS30TheDirectoryIsTheResolvedHTMLFiles() {
        let beside = Disk([file: Data("{}".utf8), "/c/dash.html": Data()], links: [html: "/c/dash.html"])
        XCTAssertEqual(read(beside), .refused(CardDataRead.leadsOutside), "read beside the HTML file's name")
        XCTAssertEqual(beside.opened, [])

        let disk = Disk(
            ["/c/stats.json": Data("{}".utf8), "/c/dash.html": Data()],
            links: [html: "/c/dash.html", file: "/c/stats.json"]
        )
        XCTAssertEqual(read(disk), .text("{}"))
        XCTAssertEqual(disk.opened, ["/c/stats.json"])
    }

    func testS30AResolveThatFailsForEitherFileIsARefusalAndNoRead() {
        let dataGone = Disk([html: Data()])
        XCTAssertEqual(read(dataGone), .refused(missing))
        XCTAssertEqual(dataGone.opened, [])

        let cardGone = Disk([file: Data("{}".utf8)])
        XCTAssertEqual(read(cardGone), .refused("the card's file: \(missing)"))
        XCTAssertEqual(cardGone.opened, [])
    }

    /// The disk's own read fails only for a file that is not there, which
    /// resolve has refused already: a stand-in read gives the other failures.
    func testS30AReadThatFailsGivesItsReason() {
        let disk = holding("{}")
        for error in [FileBytes.NotAFile(), FileBytes.TooLarge(limit: FileBytes.sizeCap)] as [any Error] {
            let outcome = CardDataRead.read(file: file, html: html, resolve: disk.resolve, read: { _ in .failure(error) })
            XCTAssertEqual(outcome, .refused(error.localizedDescription))
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
