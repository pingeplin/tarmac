import XCTest
@testable import TarmacKit

final class TermGridTests: XCTestCase {
    private typealias Size = TermGrid.Size

    // MARK: - spawn

    func testASpawnAsksForTheMeasuredGrid() {
        XCTAssertEqual(TermGrid.spawn(cols: 55, rows: 14), Size(cols: 55, rows: 14))
    }

    func testASpawnIsFlooredAtTwoByTwo() {
        XCTAssertEqual(TermGrid.spawn(cols: 1, rows: 1), Size(cols: 2, rows: 2))
        XCTAssertEqual(TermGrid.spawn(cols: 0, rows: 40), Size(cols: 2, rows: 40))
        XCTAssertEqual(TermGrid.spawn(cols: 80, rows: -3), Size(cols: 80, rows: 2))
    }

    // MARK: - resize

    func testAChangedGridOnScreenIsSent() {
        XCTAssertEqual(
            TermGrid.resize(Size(cols: 60, rows: 14), onScreen: true, lastSent: Size(cols: 55, rows: 14)),
            Size(cols: 60, rows: 14)
        )
    }

    func testAnUnchangedGridIsNotSentAgain() {
        XCTAssertNil(TermGrid.resize(Size(cols: 55, rows: 14), onScreen: true, lastSent: Size(cols: 55, rows: 14)))
    }

    /// A re-bound terminal has told the daemon nothing yet, so its first
    /// measurement goes out even if the PTY already has that size.
    func testTheFirstMeasurementIsAlwaysSent() {
        XCTAssertEqual(
            TermGrid.resize(Size(cols: 55, rows: 14), onScreen: true, lastSent: nil),
            Size(cols: 55, rows: 14)
        )
    }

    /// A card on a board that is not shown must never shrink a running program.
    func testACardThatIsNotOnScreenProposesNothing() {
        XCTAssertNil(TermGrid.resize(Size(cols: 60, rows: 14), onScreen: false, lastSent: Size(cols: 55, rows: 14)))
        XCTAssertNil(TermGrid.resize(Size(cols: 60, rows: 14), onScreen: false, lastSent: nil))
    }

    func testAZeroSizeCardProposesNothing() {
        XCTAssertNil(TermGrid.resize(Size(cols: 0, rows: 14), onScreen: true, lastSent: Size(cols: 55, rows: 14)))
        XCTAssertNil(TermGrid.resize(Size(cols: 55, rows: 0), onScreen: true, lastSent: nil))
        XCTAssertNil(TermGrid.resize(Size(cols: -1, rows: -1), onScreen: true, lastSent: nil))
    }
}
