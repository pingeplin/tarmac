import XCTest
@testable import TarmacKit

/// The path rule of spec 2611.0002 (S15–S18): a card's data file is a file in
/// its own HTML file's directory, judged in the text.
final class CardDataPathTests: XCTestCase {
    private let html = "/a/b/dash.html"

    private func judged(_ name: String) -> CardDataPath.Judgement {
        CardDataPath.dataFile(html: html, name: name)
    }

    func testS15ANameThatLeadsToAFileBesideTheCardGivesThatFile() {
        for name in ["stats.json", "./stats.json", ".//stats.json", "x/../stats.json", "/a/b/stats.json"] {
            XCTAssertEqual(judged(name), .file("/a/b/stats.json"), name)
        }
    }

    func testS16ANameInASubdirectoryIsRefusedWithThePathItLeadsTo() {
        for name in ["sub/stats.json", "/a/b/sub/stats.json"] {
            XCTAssertEqual(
                judged(name), .refused(path: "/a/b/sub/stats.json", reason: CardDataPath.inSubdirectory), name
            )
        }
        XCTAssertEqual(judged("sub/deeper/x.json"), .refused(path: "/a/b/sub/deeper/x.json", reason: CardDataPath.inSubdirectory))
    }

    func testS17ANameThatLeadsOutOfTheDirectoryIsRefusedAsOutside() {
        let cases = [
            ("../stats.json", "/a/stats.json"), ("/etc/passwd", "/etc/passwd"), ("sub/../../x.json", "/a/x.json"),
        ]
        for (name, path) in cases {
            XCTAssertEqual(judged(name), .refused(path: path, reason: CardDataPath.outside), name)
        }
    }

    /// A path is bytes to the file system. Swift joins a `/` to a combining
    /// mark that follows it, and compares strings by canonical equivalence:
    /// a rule written on characters loses the slash, or takes two
    /// directories for one.
    func testS18aAPathIsJudgedAsBytes() {
        let mark = "\u{301}"
        XCTAssertEqual(
            judged("sub/\(mark)x.json"),
            .refused(path: "/a/b/sub/\(mark)x.json", reason: CardDataPath.inSubdirectory)
        )
        XCTAssertEqual(judged("../\(mark)x.json"), .refused(path: "/a/\(mark)x.json", reason: CardDataPath.outside))
        XCTAssertEqual(CardDataPath.dataFile(html: "/a/b/\(mark)dash.html", name: "x.json"), .file("/a/b/x.json"))
        XCTAssertEqual(
            CardDataPath.dataFile(html: "/v/\u{e9}/dash.html", name: "/v/e\(mark)/x.json"),
            .refused(path: "/v/e\(mark)/x.json", reason: CardDataPath.outside)
        )
    }

    /// A sibling whose name starts with the card's directory's is not under it.
    func testS17ASiblingDirectoryThatSharesThePrefixIsOutside() {
        XCTAssertEqual(judged("/a/bc/x.json"), .refused(path: "/a/bc/x.json", reason: CardDataPath.outside))
    }

    /// `..` above the root stays at the root, as POSIX has it.
    func testS17ANameThatClimbsPastTheRootIsOutside() {
        XCTAssertEqual(judged("../../../../x.json"), .refused(path: "/x.json", reason: CardDataPath.outside))
    }

    func testS18ANameThatNamesNoFileIsRefused() {
        for name in ["", ".", "./", "x/..", "stats.json/", "st\u{0}ats.json"] {
            guard case .refused(_, let reason) = judged(name) else {
                XCTFail("\(name.debugDescription) was taken")
                continue
            }
            XCTAssertEqual(reason, CardDataPath.namesNoFile, name.debugDescription)
        }
        XCTAssertEqual(judged("x/.."), .refused(path: "/a/b", reason: CardDataPath.namesNoFile))
        XCTAssertEqual(judged("stats.json/"), .refused(path: "/a/b/stats.json", reason: CardDataPath.namesNoFile))
    }

    func testACardAtTheRootTakesAFileBesideIt() {
        XCTAssertEqual(CardDataPath.dataFile(html: "/dash.html", name: "x.json"), .file("/x.json"))
        XCTAssertEqual(
            CardDataPath.dataFile(html: "/dash.html", name: "s/x.json"),
            .refused(path: "/s/x.json", reason: CardDataPath.inSubdirectory)
        )
    }
}
