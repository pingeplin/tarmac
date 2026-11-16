import XCTest
import TarmacKit

final class CardSignalTests: XCTestCase {
    func testTheNamesAreTheInboxTagsAndTheSnapshotValues() {
        XCTAssertEqual(
            [CardSignal.blocked, .bell, .exit, .done, .live].map(\.rawValue),
            ["blocked", "bell", "exit", "done", "live"]
        )
    }
}
