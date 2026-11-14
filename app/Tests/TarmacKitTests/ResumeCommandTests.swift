import XCTest
import TarmacKit

/// 2611.0011 S31: the same table as `tarmac-protocol`'s `resume_cmd_cases`, so
/// both languages accept and refuse the same commands with the same cause.
final class ResumeCommandTests: XCTestCase {
    private let combining = String(repeating: "e\u{301}", count: 127) + "ab"

    private var cases: [(String, String?)] {
        [
            ("claude --resume ab-12", nil),
            ("cd /Users/u/文件/專案 && ls", nil),
            (String(repeating: "a", count: 256), nil),
            (combining, nil),
            (combining + "x", "over 256 characters"),
            (String(repeating: "a", count: 257), "over 256 characters"),
            ("", "empty"),
            ("   ", "empty"),
            ("echo a\necho b", "a control character"),
            ("echo a\rb", "a control character"),
            ("echo\ta", "a control character"),
            ("echo \u{1b}[2J", "a control character"),
            ("echo \u{7f}", "a control character"),
            ("echo \u{9b}x", "a control character"),
            ("echo a\u{2028}b", "a control character"),
            ("echo a\u{2029}b", "a control character"),
            ("echo \u{202e}x", "an invisible format character"),
            ("echo \u{200b}x", "an invisible format character"),
            ("echo \u{2066}x", "an invisible format character"),
            ("echo \u{061c}x", "an invisible format character"),
            ("echo \u{2064}x", "an invisible format character"),
            ("echo \u{feff}x", "an invisible format character"),
        ]
    }

    func testTheTableOfCases() {
        XCTAssertEqual(combining.unicodeScalars.count, 256)
        XCTAssertLessThan(combining.count, 256)
        for (cmd, cause) in cases {
            XCTAssertEqual(ResumeCommand.check(cmd), cause, cmd.debugDescription)
        }
    }
}
