import XCTest
@testable import TarmacKit

/// 2611.0022 D4–D8a: the markdown card's sidebar mode, its width range, what
/// the page's actions do to the card's choice, and the page's reports.
final class DocSidebarTests: XCTestCase {
    private typealias Stored = DocSidebar.Stored

    private let wide = 1280.0
    private let narrow = 392.0

    private func mode(
        _ cardWidth: Double, hasContent: Bool = true, stored: Stored = Stored(), overlayOpen: Bool = false
    ) -> DocSidebar.Mode {
        DocSidebar.mode(cardWidth: cardWidth, hasContent: hasContent, stored: stored, overlayOpen: overlayOpen)
    }

    private func apply(
        _ action: DocSidebar.Action, _ cardWidth: Double, stored: Stored = Stored(), overlayOpen: Bool = false
    ) -> (stored: Stored, overlayOpen: Bool) {
        DocSidebar.apply(action, stored: stored, overlayOpen: overlayOpen, cardWidth: cardWidth)
    }

    /// S13
    func test2611_0022S13NoContentIsNoSidebarAtAnyWidth() {
        for cardWidth in [160.0, 392, 632, 1280] {
            XCTAssertEqual(mode(cardWidth, hasContent: false), .none, "\(cardWidth)")
            XCTAssertEqual(
                mode(cardWidth, hasContent: false, stored: Stored(width: 300, open: true), overlayOpen: true), .none,
                "\(cardWidth)"
            )
        }
    }

    /// S14
    func test2611_0022S14ACardIsWideFrom632() {
        XCTAssertEqual(mode(632), .docked(240))
        XCTAssertEqual(mode(631), .strip)
    }

    /// S15
    func test2611_0022S15ADockedWidthIsClampedToTheRange() {
        XCTAssertEqual(mode(700, stored: Stored(width: 400)), .docked(308))
        XCTAssertEqual(mode(wide, stored: Stored(width: 400)), .docked(400))
        XCTAssertEqual(mode(wide, stored: Stored(width: 100)), .docked(160))
        XCTAssertEqual(DocSidebar.range(cardWidth: 632), 160...240)
        XCTAssertEqual(DocSidebar.range(cardWidth: wide), 160...420)
    }

    /// S16
    func test2611_0022S16AClosedWideCardShowsTheStrip() {
        XCTAssertEqual(mode(wide, stored: Stored(open: false)), .strip)
    }

    /// S17
    func test2611_0022S17AnOverlayKeepsClearOfTheScrollThumb() {
        XCTAssertEqual(mode(narrow, overlayOpen: true), .overlay(240))
        XCTAssertEqual(mode(narrow, stored: Stored(width: 420), overlayOpen: true), .overlay(342))
        XCTAssertEqual(mode(160, overlayOpen: true), .overlay(110))
        XCTAssertEqual(mode(narrow), .strip)
        XCTAssertEqual(DocSidebar.range(cardWidth: narrow), 160...342)
        XCTAssertEqual(DocSidebar.range(cardWidth: 160), 110...110)
        XCTAssertEqual(DocSidebar.range(cardWidth: 211), 160...161)
        for (cardWidth, resizable) in [(160.0, false), (210, false), (211, true), (392, true), (1280, true)] {
            XCTAssertEqual(DocSidebar.resizable(cardWidth: cardWidth), resizable, "\(cardWidth)")
        }
    }

    /// S17a
    func test2611_0022S17aAnOpenOverlayIsDroppedWhenTheCardIsWide() {
        XCTAssertFalse(DocSidebar.overlayOpen(true, cardWidth: 632))
        XCTAssertTrue(DocSidebar.overlayOpen(true, cardWidth: 631))
        XCTAssertFalse(DocSidebar.overlayOpen(false, cardWidth: narrow))
    }

    /// S19
    func test2611_0022S19OpenAndClose() {
        let wideOpen = apply(.open, wide, stored: Stored(open: false))
        XCTAssertEqual(wideOpen.stored, Stored(open: true))
        XCTAssertFalse(wideOpen.overlayOpen)

        let narrowOpen = apply(.open, narrow)
        XCTAssertEqual(narrowOpen.stored, Stored())
        XCTAssertTrue(narrowOpen.overlayOpen)

        XCTAssertEqual(apply(.close, wide, stored: Stored(open: true)).stored, Stored(open: false))

        let narrowClose = apply(.close, narrow, overlayOpen: true)
        XCTAssertEqual(narrowClose.stored, Stored())
        XCTAssertFalse(narrowClose.overlayOpen)
    }

    /// S20
    func test2611_0022S20ResizeStoresTheWidthAndBelowTheMinimumCollapses() {
        XCTAssertEqual(apply(.resize(300), wide).stored.width, 300)
        XCTAssertEqual(apply(.resize(500), wide).stored.width, 420)
        XCTAssertEqual(apply(.resize(150), wide, stored: Stored(width: 260, open: true)).stored, Stored(width: 260, open: false))

        let collapsed = apply(.resize(150), narrow, overlayOpen: true)
        XCTAssertEqual(collapsed.stored, Stored())
        XCTAssertFalse(collapsed.overlayOpen)

        let resized = apply(.resize(300), narrow)
        XCTAssertEqual(resized.stored.width, 300)
        XCTAssertFalse(resized.overlayOpen)
    }

    /// S21
    func test2611_0022S21ResetIsTheStandardWidthOpen() {
        XCTAssertEqual(apply(.reset, wide, stored: Stored(width: 300, open: false)).stored, Stored(width: 240, open: true))

        let narrowReset = apply(.reset, narrow, stored: Stored(width: 300))
        XCTAssertEqual(narrowReset.stored.width, 240)
        XCTAssertTrue(narrowReset.overlayOpen)
    }

    /// S22
    func test2611_0022S22ACardResizedAcrossTheThresholdKeepsItsChoice() {
        let stored = Stored(width: 300, open: true)

        XCTAssertEqual(mode(wide, stored: stored), .docked(300))
        XCTAssertEqual(mode(600, stored: stored), .strip)
        XCTAssertEqual(mode(wide, stored: stored), .docked(300))
    }

    /// S23
    func test2611_0022S23ThePagesReport() {
        XCTAssertEqual(DocSidebar.Action(report: ["action": "open"]), .open)
        XCTAssertEqual(DocSidebar.Action(report: ["action": "close"]), .close)
        XCTAssertEqual(DocSidebar.Action(report: ["action": "reset"]), .reset)
        XCTAssertEqual(DocSidebar.Action(report: ["action": "resize", "width": 250]), .resize(250))
        XCTAssertEqual(DocSidebar.Action(report: ["action": "resize", "width": 250.5]), .resize(250.5))
        XCTAssertEqual(DocSidebar.Action(report: ["action": "open", "width": 3]), .open)

        let refused: [Any] = [
            ["action": "resize"],
            ["action": "resize", "width": "250"],
            ["action": "resize", "width": NSNumber(value: true)],
            ["action": "resize", "width": Double.nan],
            ["action": "resize", "width": Double.infinity],
            ["action": "resize", "width": 0],
            ["action": "resize", "width": -3],
            ["action": "drop"],
            [String: Any](),
            "open",
            [Any](),
        ]
        for report in refused {
            XCTAssertNil(DocSidebar.Action(report: report), "\(report)")
        }
    }

    /// S23a
    func test2611_0022S23aTheRenderResult() {
        XCTAssertEqual(DocSidebar.outlineCount(result: ["outline": 3]), 3)
        XCTAssertEqual(DocSidebar.outlineCount(result: ["outline": 0]), 0)
        let refused: [Any?] = [nil, [String: Any](), ["outline": -1], ["outline": 2.5], ["outline": "3"], ["outline": NSNumber(value: true)], [3]]
        for result in refused {
            XCTAssertNil(DocSidebar.outlineCount(result: result), "\(String(describing: result))")
        }

        XCTAssertFalse(DocSidebar.hasContent(fieldCount: 0, outlineCount: 0))
        XCTAssertTrue(DocSidebar.hasContent(fieldCount: 1, outlineCount: 0))
        XCTAssertTrue(DocSidebar.hasContent(fieldCount: 0, outlineCount: 1))
    }
}
