import XCTest
@testable import TarmacKit

/// The texts an HTML card takes in one main-loop turn (spec 2611.0003
/// S31–S33).
final class CardEventBatchTests: XCTestCase {
    func testS31TheFirstTextAsksForAFlushAndTheNextBeforeItDoesNot() {
        var batch = CardEventBatch()
        XCTAssertTrue(batch.add("a"))
        XCTAssertFalse(batch.add("b"))
    }

    func testS32ATakeGivesTheTextsInOrderAndEmptiesTheBatch() {
        var batch = CardEventBatch()
        for text in ["a", "b", "c"] { batch.add(text) }
        XCTAssertEqual(batch.take(), ["a", "b", "c"])
        XCTAssertEqual(batch.take(), [])
        XCTAssertTrue(batch.add("d"))
        XCTAssertEqual(batch.take(), ["d"])
    }

    func testS33ADroppedBatchGivesNothing() {
        var batch = CardEventBatch()
        batch.add("a")
        batch.add("b")
        batch.drop()
        XCTAssertEqual(batch.take(), [])
    }
}
