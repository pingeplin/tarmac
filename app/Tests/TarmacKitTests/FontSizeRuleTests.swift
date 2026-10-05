import XCTest
@testable import TarmacKit

/// 2610.0006: which size a role uses, from the file and from typed text.
final class FontSizeRuleTests: XCTestCase {
    private let terminal = FontSizeRule.terminal
    private let document = FontSizeRule.document

    /// S2
    func testASavedSizeIsInEffectAndNoneIsTheStandard() {
        XCTAssertEqual(terminal.inEffect(saved: nil), 16)
        XCTAssertEqual(terminal.inEffect(saved: 13.5), 13.5)
        XCTAssertEqual(terminal.inEffect(saved: 8), 8)
        XCTAssertEqual(terminal.inEffect(saved: 32), 32)
        XCTAssertEqual(document.inEffect(saved: nil), 14)
        XCTAssertEqual(document.inEffect(saved: 10), 10)
        XCTAssertEqual(document.inEffect(saved: 24), 24)
    }

    /// S3 — the field shows the shortest form, never `16.0`.
    func testASizeIsShownInItsShortestForm() {
        XCTAssertEqual(FontSizeRule.text(16), "16")
        XCTAssertEqual(FontSizeRule.text(13.5), "13.5")
        XCTAssertEqual(FontSizeRule.text(8), "8")
    }

    /// S3
    func testATypedSizeIsRead() {
        XCTAssertEqual(terminal.typed("20"), 20)
        XCTAssertEqual(terminal.typed(" 13.5 "), 13.5)
    }

    /// S41 — a size already in effect is not a change, whatever the file
    /// holds: a number the reader refused stays there until a real choice.
    func testOnlyASizeThatIsNotInEffectIsAChoice() {
        XCTAssertNil(terminal.choice(16, saved: nil))
        XCTAssertNil(terminal.choice(16, saved: 64))
        XCTAssertNil(terminal.choice(20, saved: 20))
        XCTAssertEqual(terminal.choice(20, saved: nil), 20)
        XCTAssertEqual(terminal.choice(20, saved: 64), 20)
        XCTAssertEqual(terminal.choice(16, saved: 20), 16)
        XCTAssertNil(terminal.choice(64, saved: nil))
        XCTAssertNil(terminal.choice(13.3, saved: nil))
    }

    /// S20 — the file's rule: inside the role's own range, and on a half step.
    func testOnlyAHalfStepInsideTheRangeIsAccepted() {
        for size in [8, 8.5, 16, 31.5, 32] { XCTAssertTrue(terminal.accepts(size), "\(size)") }
        let refused = [7.5, 32.5, 0, -16, 16.25, 13.3, 13.500000000000002, .nan, .infinity]
        for size in refused {
            XCTAssertFalse(terminal.accepts(size), "\(size)")
            XCTAssertEqual(terminal.inEffect(saved: size), 16, "\(size)")
        }
        for size in [10.0, 24] { XCTAssertTrue(document.accepts(size), "\(size)") }
        for size in [9.5, 24.5, 28] {
            XCTAssertFalse(document.accepts(size), "\(size)")
            XCTAssertEqual(document.inEffect(saved: size), 14, "\(size)")
        }
    }

    /// S21 — the typed rule: the nearest half step, a tie going up, then the range.
    func testANumberGoesToTheNearestSizeTheRoleHas() {
        let cases: [(Double, Double)] = [(13.3, 13.5), (13.2, 13), (13.25, 13.5), (13.75, 14), (7, 8), (-5, 8), (99, 32)]
        for (typed, size) in cases { XCTAssertEqual(terminal.nearest(to: typed), size, "\(typed)") }
        XCTAssertEqual(document.nearest(to: 9), 10)
        XCTAssertEqual(document.nearest(to: 30), 24)
    }

    /// S22
    func testTextThatIsNotAFiniteNumberIsNoSize() {
        for text in ["abc", "", "   ", "nan", "inf", "-inf", "1e400", "13,5", "16pt"] {
            XCTAssertNil(terminal.typed(text), text.debugDescription)
        }
        XCTAssertEqual(terminal.typed("99"), 32)
        XCTAssertEqual(terminal.typed("1"), 8)
        XCTAssertEqual(terminal.typed("13.3"), 13.5)
    }
}
