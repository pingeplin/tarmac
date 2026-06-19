import XCTest
@testable import TarmacKit

/// 2606.0004: the card-focus branch of the ESC cascade (issue #15) — a focused
/// doc defocuses; a focused terminal (or nothing) passes through to the program.
final class EscFocusActionTests: XCTestCase {
    func testFocusedDocDefocuses() {
        XCTAssertEqual(EscFocusAction.forFocusedDoc(true), .defocus)
    }

    /// Anti-regression: a non-doc focus (a focused terminal, or nothing focused)
    /// must NOT defocus, so ESC keeps reaching the terminal program
    /// (agent-interrupt / vim). It must return nil, never `.defocus`.
    func testNonDocPassesThrough() {
        XCTAssertNil(EscFocusAction.forFocusedDoc(false))
    }
}
