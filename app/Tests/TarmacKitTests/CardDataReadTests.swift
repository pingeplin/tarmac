import XCTest
@testable import TarmacKit

/// The read of a card's data file (spec 2611.0002 S30, S32; 2611.0005 S6,
/// S33), with a stand-in
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

    func test2611_0002S30AFileBesideTheCardIsReadAsText() {
        let disk = holding(#"{"n":1}"#)
        XCTAssertEqual(read(disk), .text(#"{"n":1}"#))
        XCTAssertEqual(disk.opened, [file])
    }

    func test2611_0002S30_2611_0005S5ANameThatResolvesToAnotherDirectoryIsNeverRead() {
        for target in ["/etc/stats.json", "/a/bc/stats.json"] {
            let disk = Disk([html: Data(), file: Data("{}".utf8), target: Data("{}".utf8)], links: [file: target])
            XCTAssertEqual(read(disk), .refused(CardDataRead.leadsOutside), target)
            XCTAssertEqual(disk.opened, [], target)
        }
    }

    /// The directories are compared as bytes (`CardDataPathTests`): a
    /// combining mark after a slash does not hide the slash, and two forms of
    /// one letter are two directories.
    func test2611_0002S30_2611_0005S5TheResolvedDirectoryIsComparedAsBytes() {
        let mark = "\u{301}"
        let under = "/a/b/sub/\(mark)x.json"
        let disk = Disk([html: Data(), under: Data("{}".utf8)], links: [file: under])
        XCTAssertEqual(read(disk), .text("{}"))
        XCTAssertEqual(disk.opened, [under])

        let composed = "/v/\u{e9}/dash.html"
        let decomposed = "/v/e\(mark)/x.json"
        let other = Disk([composed: Data(), decomposed: Data("{}".utf8)], links: ["/v/\u{e9}/stats.json": decomposed])
        XCTAssertEqual(
            CardDataRead.read(file: "/v/\u{e9}/stats.json", html: composed, resolve: other.resolve, read: other.read),
            .refused(CardDataRead.leadsOutside)
        )
        XCTAssertEqual(other.opened, [])
    }

    /// A resolved path is taken as it is given: its directory is not worked
    /// out again from `..` components, which a resolved path does not have.
    func test2611_0002S30AResolvedPathIsNotNormalisedAgain() {
        let odd = "/a/b/l/../stats.json"
        let disk = Disk([html: Data(), odd: Data("{}".utf8)], links: [file: odd])
        XCTAssertEqual(read(disk), .refused(CardDataRead.leadsOutside))
        XCTAssertEqual(disk.opened, [])
    }

    /// The resolved file is the one read, never the name.
    func test2611_0002S30ANameThatResolvesToAnotherFileBesideTheCardReadsThatFile() {
        let disk = Disk([html: Data(), "/a/b/real.json": Data("[1]".utf8)], links: [file: "/a/b/real.json"])
        XCTAssertEqual(read(disk), .text("[1]"))
        XCTAssertEqual(disk.opened, ["/a/b/real.json"])
    }

    /// The directory is the resolved HTML file's, not its name's.
    func test2611_0002S30TheDirectoryIsTheResolvedHTMLFiles() {
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

    func test2611_0005S6AResolvedFileUnderTheCardsDirectoryIsReadAndOneOutsideIsNot() {
        let link = "/a/b/link/x.json"
        let away = Disk([html: Data(), "/elsewhere/x.json": Data("{}".utf8)], links: [link: "/elsewhere/x.json"])
        XCTAssertEqual(
            CardDataRead.read(file: link, html: html, resolve: away.resolve, read: away.read),
            .refused(CardDataRead.leadsOutside)
        )
        XCTAssertEqual(away.opened, [])

        let other = Disk([html: Data(), "/a/b/other/x.json": Data("[1]".utf8)], links: [link: "/a/b/other/x.json"])
        XCTAssertEqual(CardDataRead.read(file: link, html: html, resolve: other.resolve, read: other.read), .text("[1]"))
        XCTAssertEqual(other.opened, ["/a/b/other/x.json"])

        let deeper = Disk([html: Data(), "/a/b/sub/stats.json": Data("[2]".utf8)], links: [file: "/a/b/sub/stats.json"])
        XCTAssertEqual(read(deeper), .text("[2]"))
        XCTAssertEqual(deeper.opened, ["/a/b/sub/stats.json"])

        let real = Disk(
            ["/real/dash.html": Data(), "/real/sub/x.json": Data("[3]".utf8)],
            links: [html: "/real/dash.html", "/a/b/sub/x.json": "/real/sub/x.json"]
        )
        XCTAssertEqual(
            CardDataRead.read(file: "/a/b/sub/x.json", html: html, resolve: real.resolve, read: real.read), .text("[3]")
        )
        XCTAssertEqual(real.opened, ["/real/sub/x.json"])
    }

    /// The hidden rule on the resolved file, below the resolved HTML file's
    /// directory only.
    func test2611_0005S33AResolvedFileThatIsHiddenBelowTheCardsDirectoryIsNeverRead() {
        let name = "/a/b/data/x.json"
        for target in ["/a/b/.cfg/x.json", "/a/b/sub/.x.json"] {
            let disk = Disk([html: Data(), target: Data("{}".utf8)], links: [name: target])
            XCTAssertEqual(
                CardDataRead.read(file: name, html: html, resolve: disk.resolve, read: disk.read),
                .refused(CardDataRead.leadsToHidden), target
            )
            XCTAssertEqual(disk.opened, [], target)
        }

        let hiddenCard = Disk(
            ["/a/.b/dash.html": Data(), "/a/.b/sub/x.json": Data("{}".utf8)],
            links: [html: "/a/.b/dash.html", name: "/a/.b/sub/x.json"]
        )
        XCTAssertEqual(
            CardDataRead.read(file: name, html: html, resolve: hiddenCard.resolve, read: hiddenCard.read), .text("{}")
        )
        XCTAssertEqual(hiddenCard.opened, ["/a/.b/sub/x.json"])
    }

    func test2611_0002S30AResolveThatFailsForEitherFileIsARefusalAndNoRead() {
        let dataGone = Disk([html: Data()])
        XCTAssertEqual(read(dataGone), .refused(missing))
        XCTAssertEqual(dataGone.opened, [])

        let cardGone = Disk([file: Data("{}".utf8)])
        XCTAssertEqual(read(cardGone), .refused("the card's file: \(missing)"))
        XCTAssertEqual(cardGone.opened, [])
    }

    /// The disk's own read fails only for a file that is not there, which
    /// resolve has refused already: a stand-in read gives the other failures.
    func test2611_0002S30AReadThatFailsGivesItsReason() {
        let disk = holding("{}")
        for error in [FileBytes.NotAFile(), FileBytes.TooLarge(limit: FileBytes.sizeCap)] as [any Error] {
            let outcome = CardDataRead.read(file: file, html: html, resolve: disk.resolve, read: { _ in .failure(error) })
            XCTAssertEqual(outcome, .refused(error.localizedDescription))
        }
    }

    // MARK: - the bytes (S32)

    func test2611_0002S32BytesThatAreNotUTF8AreRefused() {
        XCTAssertEqual(read(holding([0x22, 0xff, 0x22])), .refused(CardDataRead.notUTF8))
    }

    func test2611_0002S32NestingIsTakenTo127LevelsAndNoDeeper() {
        let nested = { (depth: Int) in String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }
        XCTAssertEqual(read(holding(nested(127))), .text(nested(127)))
        XCTAssertEqual(read(holding(nested(128))), .refused(CardDataRead.notJSON))
    }

    func test2611_0002S32AnyValueIsTakenAtTheTopWithWhiteSpaceAround() {
        for text in ["3", #""x""#, "null", " \n\t{\"a\":[1,2]}\r\n "] {
            XCTAssertEqual(read(holding(text)), .text(text), text)
        }
    }

    func test2611_0002S32WhatStrictJSONRefusesIsRefused() {
        for bytes in [[], [0xef, 0xbb, 0xbf] + Array("{}".utf8), Array("1e400".utf8), Array(#""\ud800""#.utf8)] {
            XCTAssertEqual(read(holding(bytes)), .refused(CardDataRead.notJSON), "\(bytes)")
        }
    }
}
