import Foundation
import XCTest
@testable import TarmacKit

/// Where a card's content is scrolled to, and what a web card may say about
/// it (spec 2610.0003).
final class ScrollMetricsTests: XCTestCase {
    private let sample = ScrollMetrics(offset: 30, visible: 100, total: 400)

    func testS1ItHoldsWhatItWasGivenAndSaysWhetherTheContentOverflows() throws {
        let metrics = try XCTUnwrap(sample)
        XCTAssertEqual(metrics.offset, 30)
        XCTAssertEqual(metrics.visible, 100)
        XCTAssertEqual(metrics.total, 400)
        XCTAssertTrue(metrics.overflows)

        let fits = try XCTUnwrap(ScrollMetrics(offset: 0, visible: 100, total: 100))
        XCTAssertFalse(fits.overflows)
    }

    // MARK: - a web card's report

    func testS2AReportIsADictionaryOfThreeNumbers() throws {
        let sample = try XCTUnwrap(sample)
        XCTAssertEqual(ScrollMetrics(report: ["offset": 30, "visible": 100, "total": 400]), sample)
        XCTAssertEqual(ScrollMetrics(report: ["offset": 30.0, "visible": 100.0, "total": 400.0]), sample)
        let boxed: [String: Any] = [
            "offset": NSNumber(value: 30), "visible": NSNumber(value: 100), "total": NSNumber(value: 400),
        ]
        XCTAssertEqual(ScrollMetrics(report: boxed), sample)
        XCTAssertEqual(
            ScrollMetrics(report: ["tarmac": "scrolled", "offset": 30, "visible": 100, "total": 400] as [String: Any]),
            sample
        )
    }

    /// A page's 0 and 1 bridge to `Bool` as its `true` does; only the last is
    /// not a number.
    func testS2AZeroAndAOneAreNumbers() {
        let report: [String: Any] = [
            "offset": NSNumber(value: 0), "visible": NSNumber(value: 1), "total": NSNumber(value: 1),
        ]
        XCTAssertEqual(ScrollMetrics(report: report), ScrollMetrics(offset: 0, visible: 1, total: 1))
        XCTAssertNotNil(ScrollMetrics(report: report))
    }

    func testS33AReportThatIsNotThreeNumbersIsRefused() {
        let refused: [Any] = [
            ["offset": 30, "visible": 100],
            ["visible": 100, "total": 400],
            ["offset": "30", "visible": 100, "total": 400] as [String: Any],
            ["offset": 30, "visible": true, "total": 400] as [String: Any],
            ["offset": 30, "visible": NSNumber(value: true), "total": 400] as [String: Any],
            ["offset": 30, "visible": 100, "total": NSNull()] as [String: Any],
            [30, 100, 400],
            "30 100 400",
            ["offset": 30, "visible": 0, "total": 400],
        ]
        for report in refused {
            XCTAssertNil(ScrollMetrics(report: report), "\(report)")
        }
    }

    // MARK: - validation

    /// An overscroll is the nearest edge, not a refusal.
    func testS20TheOffsetIsClampedIntoItsRange() {
        XCTAssertEqual(ScrollMetrics(offset: -5, visible: 100, total: 400)?.offset, 0)
        XCTAssertEqual(ScrollMetrics(offset: 350, visible: 100, total: 400)?.offset, 300)
        XCTAssertEqual(ScrollMetrics(offset: 40, visible: 100, total: 100)?.offset, 0)
        XCTAssertEqual(ScrollMetrics(offset: -40, visible: 100, total: 100)?.offset, 0)
    }

    func testS32NumbersThatDescribeNoScrollerAreRefused() {
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(ScrollMetrics(offset: bad, visible: 100, total: 400), "offset \(bad)")
            XCTAssertNil(ScrollMetrics(offset: 30, visible: bad, total: 400), "visible \(bad)")
            XCTAssertNil(ScrollMetrics(offset: 30, visible: 100, total: bad), "total \(bad)")
        }
        XCTAssertNil(ScrollMetrics(offset: 0, visible: 0, total: 400))
        XCTAssertNil(ScrollMetrics(offset: 0, visible: -1, total: 400))
        XCTAssertNil(ScrollMetrics(offset: 0, visible: 100, total: 99))
    }
}
