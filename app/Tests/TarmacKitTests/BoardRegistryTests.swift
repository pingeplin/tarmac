import XCTest
@testable import TarmacKit

/// M3: pure board-list navigation (next-in-order wrapping, ⌘1..9 ordinal map).
final class BoardRegistryTests: XCTestCase {
    private let three = [
        BoardMeta(boardID: "board-0"),
        BoardMeta(boardID: "board-1", name: "infra"),
        BoardMeta(boardID: "board-2"),
    ]

    func testNextWrapsThroughOrder() {
        XCTAssertEqual(BoardRegistry.nextBoardID(after: "board-0", in: three), "board-1")
        XCTAssertEqual(BoardRegistry.nextBoardID(after: "board-1", in: three), "board-2")
        XCTAssertEqual(BoardRegistry.nextBoardID(after: "board-2", in: three), "board-0", "wraps last → first")
    }

    func testNextWithSingleBoardIsNil() {
        XCTAssertNil(BoardRegistry.nextBoardID(after: "board-0", in: [BoardMeta(boardID: "board-0")]))
    }

    func testNextWithNoBoardsIsNil() {
        XCTAssertNil(BoardRegistry.nextBoardID(after: "board-0", in: []))
    }

    func testNextWithUnknownCurrentFallsBackToFirst() {
        XCTAssertEqual(BoardRegistry.nextBoardID(after: "ghost", in: three), "board-0")
    }

    func testOrdinalIsOneBased() {
        XCTAssertEqual(BoardRegistry.boardID(forOrdinal: 1, in: three), "board-0")
        XCTAssertEqual(BoardRegistry.boardID(forOrdinal: 3, in: three), "board-2")
    }

    func testOrdinalOutOfRangeIsNil() {
        XCTAssertNil(BoardRegistry.boardID(forOrdinal: 0, in: three))
        XCTAssertNil(BoardRegistry.boardID(forOrdinal: 4, in: three))
    }
}
