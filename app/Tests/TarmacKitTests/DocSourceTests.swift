import XCTest
@testable import TarmacKit

/// What a markdown doc card shows: its file as UTF-8 text, or why it could not
/// be read.
final class DocSourceTests: XCTestCase {
    func testAnUnreadableDocRendersItsPathAndTheErrorInAFencedBlock() {
        XCTAssertEqual(
            DocSource.unreadable(path: "/r/a.md", reason: "No such file or directory (os error 2)"),
            "*could not read /r/a.md*\n\n```\nNo such file or directory (os error 2)\n```"
        )
    }

    func testAReadableFileIsItsText() {
        XCTAssertEqual(DocSource.markdown(path: "/r/a.md", contents: .success(Data("# hi\n".utf8))), "# hi\n")
    }

    /// A file that is not UTF-8 is an error, not a lossy decode.
    func testBytesThatAreNotUTF8AreUnreadable() {
        let text = DocSource.markdown(path: "/r/a.md", contents: .success(Data([0x66, 0xFF, 0x6F])))
        XCTAssertTrue(text.hasPrefix("*could not read /r/a.md*\n\n```\n"), text)
        XCTAssertTrue(text.hasSuffix("\n```"), text)
    }

    func testAReadErrorIsUnreadable() {
        struct Failure: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        XCTAssertEqual(
            DocSource.markdown(path: "/r/a.md", contents: .failure(Failure())),
            "*could not read /r/a.md*\n\n```\nboom\n```"
        )
    }
}
