import CoreGraphics
import XCTest
@testable import TarmacKit

/// Spec 2611.0013 S26: the inbox panel's strip and the board area it leaves.
final class InboxPanelLayoutTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1100, height: 673)

    func testS26ThePanelIsAThirdOfTheAreaUpTo360FlushRightAndFullHeight() {
        XCTAssertEqual(InboxPanelLayout.width(area), 360)
        XCTAssertEqual(InboxPanelLayout.width(CGRect(x: 0, y: 0, width: 900, height: 600)), 300)
        XCTAssertEqual(InboxPanelLayout.width(CGRect(x: 0, y: 0, width: 1000, height: 600)), 333)
        XCTAssertEqual(InboxPanelLayout.panelRect(area), CGRect(x: 740, y: 0, width: 360, height: 673))
        XCTAssertEqual(
            InboxPanelLayout.panelRect(CGRect(x: 0, y: 22, width: 900, height: 600)),
            CGRect(x: 600, y: 22, width: 300, height: 600)
        )
    }

    func testS26TheUncoveredAreaIsTheAreaLeftOfTheOpenPanel() {
        XCTAssertEqual(InboxPanelLayout.uncovered(area, open: true), CGRect(x: 0, y: 0, width: 740, height: 673))
        XCTAssertEqual(InboxPanelLayout.uncovered(area, open: false), area)
    }

    /// #394: the cap is what the Interface size makes of 360; a third of the
    /// area still bounds it.
    func testAScaledCapWidensThePanelUpToAThirdOfTheArea() {
        let wide = CGRect(x: 0, y: 0, width: 2000, height: 673)
        XCTAssertEqual(InboxPanelLayout.width(wide, maxWidth: 480), 480)
        XCTAssertEqual(InboxPanelLayout.width(area, maxWidth: 480), 366)
        XCTAssertEqual(InboxPanelLayout.width(wide, maxWidth: 300), 300)
        XCTAssertEqual(
            InboxPanelLayout.panelRect(wide, maxWidth: 480), CGRect(x: 1520, y: 0, width: 480, height: 673)
        )
        XCTAssertEqual(
            InboxPanelLayout.uncovered(wide, open: true, maxWidth: 480), CGRect(x: 0, y: 0, width: 1520, height: 673)
        )
        XCTAssertEqual(InboxPanelLayout.uncovered(wide, open: false, maxWidth: 480), wide)
    }

    func testS26AHintUnderThePanelIsPlacedOnThePanelsLeftEdge() {
        let options = OffscreenHintLayout.Options(
            edgeInset: 12, edgeMargin: 8, stackGap: 6, pillSize: { _ in CGSize(width: 80, height: 22) }
        )
        let hint = OffscreenHintLayout.Hint(
            cardID: "T", centerView: CGPoint(x: 800, y: 300), signal: .bell, label: "T", z: 0, signalAt: 1
        )
        let open = OffscreenHintLayout.stackPills([hint], in: InboxPanelLayout.uncovered(area, open: true), options: options)
        XCTAssertEqual(open.map(\.edge), [.right])
        XCTAssertEqual(open.first.map { $0.left + 80 }, 740 - 8)
        XCTAssertEqual(OffscreenHintLayout.stackPills([hint], in: InboxPanelLayout.uncovered(area, open: false), options: options), [])
    }
}
