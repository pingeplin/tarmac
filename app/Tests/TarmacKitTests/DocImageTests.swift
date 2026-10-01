import XCTest
@testable import TarmacKit

/// Spec 2609.0014: which markdown doc-card `<img src>` values name a local file,
/// and the absolute path each resolves to (S1–S9). The tarmac-card:// re-addressing
/// of a local image (S10–S11) is a view concern and not part of this module.
final class DocImageTests: XCTestCase {
    private func path(_ src: String, in docPath: String = "/r/README.md") -> String? {
        DocImage.localPath(src: src, docPath: docPath)
    }

    func testS1RelativeSrcJoinsOntoTheDocsDirectoryWithDotSegmentsNormalized() {
        XCTAssertEqual(path("docs/images/logo.png"), "/r/docs/images/logo.png")
        XCTAssertEqual(path("./x.png"), "/r/x.png")
        XCTAssertEqual(path("../x.png"), "/x.png")
        XCTAssertEqual(path("a/./b/../c.png"), "/r/a/c.png")
        XCTAssertEqual(path("./x:y.png"), "/r/x:y.png")
    }

    func testS2AnAbsoluteSrcKeepsItsPathNormalized() {
        XCTAssertEqual(path("/abs/dir/x.png"), "/abs/dir/x.png")
        XCTAssertEqual(path("/abs/../x.png"), "/x.png")
    }

    func testS3ALocalFileURLsPathGoesThroughTheSameSteps() {
        XCTAssertEqual(path("file:///abs/x.png"), "/abs/x.png")
        XCTAssertEqual(path("file://localhost/abs/x.png"), "/abs/x.png")
        XCTAssertEqual(path("FILE:///abs/x.png"), "/abs/x.png")
        XCTAssertEqual(path("file:///abs/my%20pic.png#x"), "/abs/my pic.png")
        XCTAssertEqual(path("file:///abs/../x.png"), "/x.png")
    }

    func testS4IsNilForAnythingButALocalFileReference() {
        let nonLocal = [
            "https://h/x.png", "HTTPS://h/x.png", "http://h/x.png", "ftp://h/x.png", " https://h/x.png",
            "data:image/png;base64,AAAA", "blob:http://localhost/u",
            "mailto:a@b.c", "tarmac-card://img/x", "x:y.png",
            "//h/x.png", "file://example.com/x.png", "file:/abs/x.png", "File:/abs/x.png", "file:abs/x.png",
            "", "   ", "#top",
        ]
        for src in nonLocal {
            XCTAssertNil(path(src), src.debugDescription)
        }
    }

    func testS5DropsEverythingFromTheFirstQuestionMarkOrHash() {
        XCTAssertEqual(path("x.png?raw=true#top"), "/r/x.png")
        XCTAssertEqual(path("/abs/x.png#frag"), "/abs/x.png")
    }

    func testS6DecodesEveryEscapeAfterTheStripFallingBackToTheWholeUndecodedPath() {
        XCTAssertEqual(path("my%20pic.png"), "/r/my pic.png")
        XCTAssertEqual(path("%E5%9C%96.png"), "/r/圖.png")
        XCTAssertEqual(path("a%23b.png"), "/r/a#b.png")
        XCTAssertEqual(path("a%3Fb.png"), "/r/a?b.png")
        XCTAssertEqual(path("100%.png"), "/r/100%.png")
        XCTAssertEqual(path("my%20pic%.png"), "/r/my%20pic%.png")
        XCTAssertEqual(path("%FF.png"), "/r/%FF.png", "an escape that is not valid UTF-8 keeps the whole path literal")
        // Classified relative before decoding; the empty segment stays, and POSIX reads // as /.
        XCTAssertEqual(path("%2Fx.png"), "/r//x.png")
    }

    /// The second doc path carries only valid escapes: with the first one's stray
    /// %, a mutant that decodes the directory falls back to literal and still passes.
    func testS7KeepsTheDocsDirectoryByteForByteNeitherDecodedNorCutAtHashOrQuestionMark() {
        XCTAssertEqual(
            path("img/x.png", in: "/tmp/my docs 100%#?/圖表/README.md"),
            "/tmp/my docs 100%#?/圖表/img/x.png"
        )
        XCTAssertEqual(path("img/x.png", in: "/tmp/a%20b/README.md"), "/tmp/a%20b/img/x.png")
    }

    func testS8TrimsASCIIWhitespaceFromBothEndsFirst() {
        XCTAssertEqual(path("  x.png  "), "/r/x.png")
        XCTAssertEqual(path("\tx.png\n"), "/r/x.png")
        XCTAssertEqual(path("\u{0C}x.png\r"), "/r/x.png")
        // VT is not one of the five trimmed characters (a general trim would strip it).
        XCTAssertEqual(path("\u{0B}x.png"), "/r/\u{0B}x.png")
    }

    func testS9NeverClimbsAboveTheRoot() {
        XCTAssertEqual(path("../../x.png"), "/x.png")
        XCTAssertEqual(path("../../../x.png"), "/x.png")
    }

    /// `\r\n` and a slash followed by a combining mark are each ONE Character in
    /// Swift, so a Character-wise trim or split would miss them; the rules read
    /// Unicode scalars, as the UTF-16 originals did.
    func testReadsScalarsNotCharacters() {
        XCTAssertEqual(path("\r\nx.png\r\n"), "/r/x.png")
        XCTAssertEqual(path("a/\u{0301}b/../c.png"), "/r/a/c.png")
    }
}
