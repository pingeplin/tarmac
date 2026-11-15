import Foundation
import XCTest
import TarmacKit

/// 2611.0011 S31: `tarmac-protocol`'s `tests/fixtures/resume_cmd_cases.json`,
/// the table its own `s31_the_resume_command_check` runs, so both languages
/// accept and refuse the same commands with the same cause; and S21, how a
/// command reads where space is short.
final class ResumeCommandTests: XCTestCase {
    private struct Table: Decodable {
        struct Case: Decodable {
            let parts: [Part]
            let cause: String?
        }

        /// A text and how many times it is repeated: `["a", 256]`.
        struct Part: Decodable {
            let text: String
            let count: Int

            init(from decoder: Decoder) throws {
                var pair = try decoder.unkeyedContainer()
                text = try pair.decode(String.self)
                count = try pair.decode(Int.self)
            }
        }

        let cases: [Case]
    }

    private func cases() throws -> [(cmd: String, cause: String?)] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("core/crates/tarmac-protocol/tests/fixtures/resume_cmd_cases.json")
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: fixture))
        return table.cases.map { c in
            (c.parts.map { String(repeating: $0.text, count: $0.count) }.joined(), c.cause)
        }
    }

    func testTheSharedTableOfCases() throws {
        let all = try cases()
        XCTAssertGreaterThan(all.count, 30)
        for (cmd, cause) in all {
            XCTAssertEqual(ResumeCommand.check(cmd), cause, cmd.debugDescription)
        }
    }

    /// A grapheme count would accept the table's 257-scalar command of
    /// combining marks.
    func testTheCombiningCaseIsCountedInScalars() throws {
        let combining = try cases()[3].cmd
        XCTAssertEqual(combining.unicodeScalars.count, 256)
        XCTAssertLessThan(combining.count, 256)
    }

    // MARK: 2611.0011 S21: how a command reads where space is short

    func testS21AMetacharacterIsNeverHidden() {
        let shown = ResumeCommand.display("claude --resume 3f2a1b9c-0000-4000-8000-000000000000; curl x|sh")
        XCTAssertTrue(shown.contains("; curl x|sh"), shown)
        XCTAssertTrue(shown.hasPrefix("claude --resume 3f2a1b9c"), shown)
    }

    func testS21APathWithNoIdLikeWordIsUnchanged() {
        XCTAssertEqual(ResumeCommand.display("rm -rf /Users/u/work/important-directory"), "rm -rf /Users/u/work/important-directory")
    }

    func testS21AFlagStaysWhole() {
        XCTAssertEqual(
            ResumeCommand.display("claude --dangerously-skip-permissions --resume 3f2a1b9c-0000-4000-8000-000000000000"),
            "claude --dangerously-skip-permissions --resume 3f2a…"
        )
        XCTAssertEqual(ResumeCommand.display("x --resume-12345678901"), "x --resume-12345678901")
    }

    func testS21ALongWordWithNoDigitStaysWhole() {
        XCTAssertEqual(ResumeCommand.display("cd important-directory"), "cd important-directory")
    }

    func testAnIdOfTwelveCharactersStaysWholeAndThirteenIsShortened() {
        XCTAssertEqual(ResumeCommand.display("x abcdefghij12"), "x abcdefghij12")
        XCTAssertEqual(ResumeCommand.display("x abcdefghij123"), "x abcd…")
    }

    func testTheSpacingIsKeptVerbatim() {
        XCTAssertEqual(ResumeCommand.display("a  b 3f2a1b9c-0000-4000"), "a  b 3f2a…")
    }
}
