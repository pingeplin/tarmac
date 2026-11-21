import XCTest
@testable import TarmacKit

/// 2611.0022 D4–D8: the markdown card's sidebar mode, its width range, what
/// the page's actions do to the card's choice, and the page's reports.
final class DocSidebarTests: XCTestCase {
    private typealias Stored = DocSidebar.Stored

    private let wide = 1280.0
    private let narrow = 392.0

    private func mode(
        _ cardWidth: Double, stored: Stored = Stored(), overlayOpen: Bool = false
    ) -> DocSidebar.Mode {
        DocSidebar.mode(cardWidth: cardWidth, stored: stored, overlayOpen: overlayOpen)
    }

    private func apply(
        _ action: DocSidebar.Action, _ cardWidth: Double, stored: Stored = Stored(), overlayOpen: Bool = false
    ) -> (stored: Stored, overlayOpen: Bool) {
        DocSidebar.apply(action, stored: stored, overlayOpen: overlayOpen, cardWidth: cardWidth)
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
        XCTAssertEqual(apply(.resize(160), wide, stored: Stored(width: 260, open: true)).stored, Stored(width: 160, open: true))
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

    /// D12: the state the page is given, its numbers all the kit's.
    func test2611_0022D12ThePageState() {
        func state(_ cardWidth: Double, stored: Stored = Stored(), overlayOpen: Bool = false) -> DocSidebar.PageState {
            DocSidebar.pageState(cardWidth: cardWidth, stored: stored, overlayOpen: overlayOpen)
        }
        typealias State = DocSidebar.PageState
        XCTAssertEqual(state(wide, stored: Stored(width: 300)), State(mode: "docked", width: 300, maxWidth: 420, resizable: true))
        XCTAssertEqual(state(700, stored: Stored(width: 400)), State(mode: "docked", width: 308, maxWidth: 308, resizable: true))
        XCTAssertEqual(state(wide, stored: Stored(open: false)), State(mode: "strip", width: 240, maxWidth: 420, resizable: true))
        XCTAssertEqual(state(narrow, stored: Stored(width: 420)), State(mode: "strip", width: 342, maxWidth: 342, resizable: true))
        XCTAssertEqual(state(narrow, overlayOpen: true), State(mode: "overlay", width: 240, maxWidth: 342, resizable: true))
        XCTAssertEqual(state(200, overlayOpen: true), State(mode: "overlay", width: 150, maxWidth: 150, resizable: false))

        let arguments = state(wide, stored: Stored(width: 300)).arguments as NSDictionary
        XCTAssertEqual(arguments, [
            "mode": "docked", "width": 300, "minWidth": 160, "maxWidth": 420, "resizable": true,
            "strip": 30, "grip": 8, "side": "left",
        ] as NSDictionary)
    }

    // MARK: - 2611.0024

    private func storesChange(
        _ action: DocSidebar.Action, _ cardWidth: Double, stored: Stored = Stored(), overlayOpen: Bool = false
    ) -> Bool {
        DocSidebar.storesChange(action, stored: stored, overlayOpen: overlayOpen, cardWidth: cardWidth)
    }

    func test2611_0024S9aAnActionThatChangesNothingStoresNothing() {
        XCTAssertFalse(storesChange(.open, narrow))
        XCTAssertFalse(storesChange(.close, narrow, overlayOpen: true))
        XCTAssertFalse(storesChange(.resize(150), narrow, stored: Stored(width: 300)))
        XCTAssertTrue(storesChange(.open, wide, stored: Stored(open: false)))
        XCTAssertTrue(storesChange(.resize(300), wide, stored: Stored(width: 240, open: true)))
        XCTAssertFalse(storesChange(.resize(240), wide, stored: Stored(width: 240, open: true)))
        XCTAssertTrue(storesChange(.resize(240), wide))
        XCTAssertTrue(storesChange(.resize(150), wide, stored: Stored(width: 300, open: true)))
        XCTAssertTrue(storesChange(.reset, wide, stored: Stored(width: 300, open: false)))
        XCTAssertFalse(storesChange(.reset, wide, stored: Stored(width: 240, open: true)))
    }

    func test2611_0024S9TheReadCheckKeepsAWidthInTheRangeAndTheOpenState() {
        let cases: [(Double?, Bool?, Stored)] = [
            (300.5, false, Stored(width: 300.5, open: false)),
            (160, nil, Stored(width: 160)),
            (420, true, Stored(width: 420, open: true)),
            (159.99, true, Stored(open: true)),
            (420.01, nil, Stored()),
            (.nan, false, Stored(open: false)),
            (.infinity, false, Stored(open: false)),
            (-.infinity, false, Stored(open: false)),
            (nil, nil, Stored()),
        ]
        for (width, open, expected) in cases {
            XCTAssertEqual(
                DocSidebar.restored(width: width, open: open), expected,
                "\(String(describing: width)), \(String(describing: open))"
            )
        }
    }

    func test2611_0024S10WhatTheAppWritesItReadsBack() {
        let actions: [DocSidebar.Action] = [
            .open, .close, .reset, .resize(150), .resize(160), .resize(300), .resize(500), .resize(1e9),
        ]
        for cardWidth in [wide, narrow] {
            for start in [Stored(), Stored(width: 260, open: true)] {
                for action in actions {
                    let s = apply(action, cardWidth, stored: start).stored
                    let read = DocSidebar.restored(width: s.width, open: s.open)
                    XCTAssertEqual(read, s, "\(cardWidth) \(start) \(action)")
                }
            }
        }
    }
}
