import XCTest
@testable import TarmacKit

final class DeskLayoutTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)

    private func assertRect(
        _ rect: CGRect, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(rect.minX, x, accuracy: 0.001, "minX", file: file, line: line)
        XCTAssertEqual(rect.minY, y, accuracy: 0.001, "minY", file: file, line: line)
        XCTAssertEqual(rect.width, w, accuracy: 0.001, "width", file: file, line: line)
        XCTAssertEqual(rect.height, h, accuracy: 0.001, "height", file: file, line: line)
    }

    func testSingleTileFillsPaddedDesk() {
        let f = DeskLayout.frames(count: 1, in: bounds)
        XCTAssertEqual(f.count, 1)
        assertRect(f[0], x: 12, y: 12, w: 976, h: 676)
    }

    func testTwoTilesSplit135To1() {
        let f = DeskLayout.frames(count: 2, in: bounds)
        XCTAssertEqual(f.count, 2)
        let c0 = 966 * 1.35 / 2.35
        assertRect(f[0], x: 12, y: 12, w: c0, h: 676)
        assertRect(f[1], x: 12 + c0 + 10, y: 12, w: 966 - c0, h: 676)
    }

    func testThreeTilesSlotZeroSpansBothRows() {
        let f = DeskLayout.frames(count: 3, in: bounds)
        XCTAssertEqual(f.count, 3)
        let c0 = 966 * 1.35 / 2.35
        let row = (676.0 - 10) / 2
        assertRect(f[0], x: 12, y: 12, w: c0, h: 676)
        assertRect(f[1], x: 12 + c0 + 10, y: 12, w: 966 - c0, h: row)
        assertRect(f[2], x: 12 + c0 + 10, y: 12 + row + 10, w: 966 - c0, h: row)
    }

    func testFourTilesRowMajor() {
        let f = DeskLayout.frames(count: 4, in: bounds)
        XCTAssertEqual(f.count, 4)
        let c0 = 966 * 1.25 / 2.25
        let r0 = 666 * 1.3 / 2.3
        assertRect(f[0], x: 12, y: 12, w: c0, h: r0)
        assertRect(f[1], x: 12 + c0 + 10, y: 12, w: 966 - c0, h: r0)
        assertRect(f[2], x: 12, y: 12 + r0 + 10, w: c0, h: 666 - r0)
        assertRect(f[3], x: 12 + c0 + 10, y: 12 + r0 + 10, w: 966 - c0, h: 666 - r0)
    }

    func testFiveTilesFlowIntoThirdRow() {
        let f = DeskLayout.frames(count: 5, in: bounds)
        XCTAssertEqual(f.count, 5)
        let c0 = 966 * 1.25 / 2.25
        let availH = 676.0 - 20
        let r0 = availH * 1.3 / 3.3
        let r1 = availH / 3.3
        assertRect(f[4], x: 12, y: 12 + r0 + 10 + r1 + 10, w: c0, h: r1)
    }

    func testEmptyDesk() {
        XCTAssertEqual(DeskLayout.frames(count: 0, in: bounds), [])
    }
}
