import XCTest
@testable import TarmacKit

/// The doc-card owner chip shows "← <label>" whenever the owner terminal still
/// exists with a non-empty label; provenance chrome never depends on gravity.
final class OwnerChipTests: XCTestCase {
    private func labels(_ entries: [String: String]) -> (String) -> String? {
        { entries[$0] }
    }

    func testOwnerWithANonEmptyLabelNamesTheChip() {
        XCTAssertEqual(OwnerChip.name(ownerTermID: "term-1", labelOf: labels(["term-1": "claude"])), "claude")
    }

    /// A dragged (loose) doc keeps its chip: the rule takes no `attached` input,
    /// so reintroducing a gravity gate would have to change this signature.
    func testLooseDocWithItsOwnerPresentStillNamesTheChip() {
        XCTAssertEqual(OwnerChip.name(ownerTermID: "term-1", labelOf: labels(["term-1": "claude"])), "claude")
    }

    func testNoOwnerHidesTheChip() {
        XCTAssertNil(OwnerChip.name(ownerTermID: nil, labelOf: labels([:])))
    }

    func testAnEmptyOwnerIDHidesTheChip() {
        XCTAssertNil(OwnerChip.name(ownerTermID: "", labelOf: labels(["": "claude"])))
    }

    func testAnOwnerThatIsGoneHidesTheChip() {
        XCTAssertNil(OwnerChip.name(ownerTermID: "term-1", labelOf: labels([:])))
    }

    func testAnEmptyOwnerLabelHidesTheChip() {
        XCTAssertNil(OwnerChip.name(ownerTermID: "term-1", labelOf: labels(["term-1": ""])))
    }
}
