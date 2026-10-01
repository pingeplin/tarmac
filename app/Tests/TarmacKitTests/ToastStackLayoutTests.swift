import XCTest
@testable import TarmacKit

final class ToastStackLayoutTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1100, height: 673)

    func testNoToastsHaveNoFrames() {
        XCTAssertEqual(ToastStackLayout.frames(sizes: [], in: area), [])
    }

    func testAToastSitsFourteenFromTheRightAndThirtyEightFromTheBottom() {
        XCTAssertEqual(
            ToastStackLayout.frames(sizes: [CGSize(width: 200, height: 36)], in: area),
            [CGRect(x: 1100 - 14 - 200, y: 673 - 38 - 36, width: 200, height: 36)]
        )
    }

    func testTheNewestIsLowestAndTheOlderOnesStackUpwardEightApart() {
        let frames = ToastStackLayout.frames(
            sizes: [CGSize(width: 100, height: 36), CGSize(width: 100, height: 50), CGSize(width: 100, height: 36)],
            in: area
        )
        let newestBottom: CGFloat = 673 - 38
        let middleBottom: CGFloat = newestBottom - 36 - 8
        let oldestBottom: CGFloat = middleBottom - 50 - 8
        XCTAssertEqual(frames.map(\.maxY), [oldestBottom, middleBottom, newestBottom])
        XCTAssertEqual(frames.map(\.height), [36, 50, 36])
    }

    func testToastsOfDifferentWidthsShareTheRightEdge() {
        let frames = ToastStackLayout.frames(
            sizes: [CGSize(width: 320, height: 36), CGSize(width: 120, height: 36)], in: area
        )
        XCTAssertEqual(frames.map(\.maxX), [1086, 1086])
        XCTAssertEqual(frames.map(\.minX), [766, 966])
    }

    func testTheColumnIsMeasuredFromTheAreaNotFromZero() {
        let offset = CGRect(x: 40, y: 20, width: 600, height: 400)
        XCTAssertEqual(
            ToastStackLayout.frames(sizes: [CGSize(width: 100, height: 30)], in: offset),
            [CGRect(x: 40 + 600 - 14 - 100, y: 20 + 400 - 38 - 30, width: 100, height: 30)]
        )
    }
}
