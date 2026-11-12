import XCTest
@testable import TarmacKit

/// The path rule of spec 2611.0002 (S15–S18), widened by 2611.0005 (S1–S5,
/// S32): a card's data file is a file in its own HTML file's directory or in
/// a directory under it, judged in the text, and no name below that directory
/// is hidden.
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

    func testS1ANameUnderTheCardsDirectoryGivesThatFileAtAnyDepth() {
        for name in ["sub/stats.json", "./sub/stats.json", "sub//stats.json", "sub/x/../stats.json", "/a/b/sub/stats.json"] {
            XCTAssertEqual(judged(name), .file("/a/b/sub/stats.json"), name)
        }
        XCTAssertEqual(judged("sub/deep/stats.json"), .file("/a/b/sub/deep/stats.json"))
    }

    func testS2ANameThatLeadsOutOfTheTreeIsRefusedAsOutside() {
        let cases = [
            ("../stats.json", "/a/stats.json"), ("/etc/passwd", "/etc/passwd"), ("sub/../../x.json", "/a/x.json"),
            ("/a/bc/x.json", "/a/bc/x.json"), ("../bc/x.json", "/a/bc/x.json"),
        ]
        for (name, path) in cases {
            XCTAssertEqual(judged(name), .refused(path: path, reason: CardDataPath.outside), name)
        }
    }

    func testS3ANameThatNamesADirectoryUnderTheCardNamesNoFile() {
        let cases = [("sub/..", "/a/b"), ("sub/../", "/a/b"), ("sub/", "/a/b/sub"), ("sub/./", "/a/b/sub")]
        for (name, path) in cases {
            XCTAssertEqual(judged(name), .refused(path: path, reason: CardDataPath.namesNoFile), name)
        }
    }

    /// A hidden name below the card's directory is refused, the file's own
    /// included; the card's directory itself may be hidden.
    func testS32AHiddenNameBelowTheCardsDirectoryIsRefused() {
        let cases = [
            (".stats.json", "/a/b/.stats.json"), (".cfg/x.json", "/a/b/.cfg/x.json"),
            ("sub/.cfg/x.json", "/a/b/sub/.cfg/x.json"), ("sub/.x.json", "/a/b/sub/.x.json"),
            ("/a/b/.cfg/x.json", "/a/b/.cfg/x.json"),
        ]
        for (name, path) in cases {
            XCTAssertEqual(judged(name), .refused(path: path, reason: CardDataPath.hidden), name)
        }
        XCTAssertEqual(judged("sub/x.json."), .file("/a/b/sub/x.json."))
        XCTAssertEqual(judged("sub/a.b/x.json"), .file("/a/b/sub/a.b/x.json"))
        XCTAssertEqual(judged("../.x.json"), .refused(path: "/a/.x.json", reason: CardDataPath.outside))
        XCTAssertEqual(judged(".cfg/"), .refused(path: "/a/b/.cfg", reason: CardDataPath.namesNoFile))
        XCTAssertEqual(CardDataPath.dataFile(html: "/a/.b/dash.html", name: "stats.json"), .file("/a/.b/stats.json"))
        XCTAssertEqual(CardDataPath.dataFile(html: "/a/.b/dash.html", name: "sub/x.json"), .file("/a/.b/sub/x.json"))
    }

    /// A path is bytes to the file system. Swift joins a `/` to a combining
    /// mark that follows it, and compares strings by canonical equivalence:
    /// a rule written on characters loses the slash, or takes two
    /// directories for one.
    func testS4S18aAPathIsJudgedAsBytes() {
        let mark = "\u{301}"
        XCTAssertEqual(judged("sub/\(mark)x.json"), .file("/a/b/sub/\(mark)x.json"))
        XCTAssertEqual(judged("../\(mark)x.json"), .refused(path: "/a/\(mark)x.json", reason: CardDataPath.outside))
        XCTAssertEqual(CardDataPath.dataFile(html: "/a/b/\(mark)dash.html", name: "x.json"), .file("/a/b/x.json"))
        XCTAssertEqual(
            CardDataPath.dataFile(html: "/v/\u{e9}/dash.html", name: "/v/e\(mark)/x.json"),
            .refused(path: "/v/e\(mark)/x.json", reason: CardDataPath.outside)
        )
        XCTAssertEqual(
            CardDataPath.dataFile(html: "/v/\u{e9}/dash.html", name: "/v/e\(mark)/sub/x.json"),
            .refused(path: "/v/e\(mark)/sub/x.json", reason: CardDataPath.outside)
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

    func testS3aACardAtTheRootTakesAFileBesideItAndUnderIt() {
        XCTAssertEqual(CardDataPath.dataFile(html: "/dash.html", name: "x.json"), .file("/x.json"))
        XCTAssertEqual(CardDataPath.dataFile(html: "/dash.html", name: "s/x.json"), .file("/s/x.json"))
    }

    /// The under-check of the read, on resolved paths taken as given: by
    /// whole components, as bytes, and nothing worked out again.
    func testS5TheUnderCheckIsByWholeComponentsAsBytes() {
        let mark = "\u{301}"
        for file in ["/a/b/x.json", "/a/b/sub/deep/x.json", "/a/b/sub/\(mark)x.json"] {
            XCTAssertNotNil(CardDataPath.below(file, html: html), file)
        }
        for file in ["/a/bc/x.json", "/a/x.json", "/x.json", "/a/b", "/a/b/l/../x.json"] {
            XCTAssertNil(CardDataPath.below(file, html: html), file)
        }
        XCTAssertNil(CardDataPath.below("/v/\u{e9}/sub/x.json", html: "/v/e\(mark)/dash.html"))
    }
}
