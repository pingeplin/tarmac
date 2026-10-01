import XCTest
@testable import TarmacKit

final class TermLabelTests: XCTestCase {
    func testACardStartsAsShell() {
        XCTAssertEqual(TermLabel.initial, "shell")
    }

    func testAProcessNameBecomesTheLabel() {
        XCTAssertEqual(TermLabel.afterProc("vim"), "vim")
    }

    func testAnEmptyProcessNameReadsAsShell() {
        XCTAssertEqual(TermLabel.afterProc(""), "shell")
    }

    func testANonBlankTitleBecomesTheLabelVerbatim() {
        XCTAssertEqual(TermLabel.afterTitle("  ~/src — zsh ", current: "vim"), "  ~/src — zsh ")
    }

    /// A program clearing its title does not revert the card to the process name.
    func testABlankTitleIsIgnored() {
        for blank in [nil, "", " ", "\t\n", "\u{0B}\u{0C}\r", "\u{00A0}\u{3000}", "\u{FEFF}", "\u{2028}\u{2029}"] {
            XCTAssertEqual(TermLabel.afterTitle(blank, current: "vim"), "vim", "\(String(describing: blank))")
        }
    }

    /// ECMAScript's `trim` leaves U+0085 alone, so a title made of it is not blank.
    func testNextLineIsNotBlank() {
        XCTAssertEqual(TermLabel.afterTitle("\u{0085}", current: "vim"), "\u{0085}")
    }

    /// There is no stored precedence: whichever source spoke last is shown.
    func testTheLastWriterWins() {
        var label = TermLabel.initial
        label = TermLabel.afterTitle("claude", current: label)
        XCTAssertEqual(label, "claude")
        label = TermLabel.afterProc("node")
        XCTAssertEqual(label, "node", "a later process name overwrites a title")
        label = TermLabel.afterTitle("", current: label)
        XCTAssertEqual(label, "node", "clearing the title reverts nothing")
        label = TermLabel.afterTitle("claude", current: label)
        XCTAssertEqual(label, "claude")
    }
}
