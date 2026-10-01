import XCTest
import TarmacKit

/// 2609.0016: the notice's placement decisions, ported from the Rust
/// `quit_notice.rs` tests.
final class QuitNoticeTests: XCTestCase {
    /// S28 — centred on the screen's usable area.
    func testTheNoticeIsCentredInTheVisibleFrame() {
        XCTAssertEqual(
            QuitNotice.frame(visibleFrame: QuitNotice.Rect(x: 100, y: 50, w: 1000, h: 800)),
            QuitNotice.Rect(x: 425, y: 415, w: 350, h: 70)
        )
    }

    /// S39 — the text is centred on the slab's own centre line, not hung from
    /// its top edge.
    func testTheLabelIsCentredInTheSlab() {
        XCTAssertEqual(QuitNotice.labelY(noticeHeight: 70, textHeight: 29), 20.5)
        XCTAssertEqual(QuitNotice.labelY(noticeHeight: 70, textHeight: 70), 0)
        // Text taller than the slab starts at the top edge rather than above it.
        XCTAssertEqual(QuitNotice.labelY(noticeHeight: 70, textHeight: 80), 0)
    }

    /// S29 — the window's own screen while it is on one; the main screen while
    /// it is hidden or minimized, which is where the user is looking.
    func testTheNoticeFollowsTheWindowUntilItLeavesTheScreen() {
        XCTAssertEqual(
            QuitNotice.pickScreen(windowScreen: "win", windowOnScreen: true, mainScreen: "main", firstScreen: "first"),
            "win"
        )
        XCTAssertEqual(
            QuitNotice.pickScreen(windowScreen: "win", windowOnScreen: false, mainScreen: "main", firstScreen: "first"),
            "main"
        )
        XCTAssertEqual(
            QuitNotice.pickScreen(windowScreen: nil, windowOnScreen: true, mainScreen: "main", firstScreen: "first"),
            "main"
        )
        XCTAssertEqual(
            QuitNotice.pickScreen(windowScreen: nil, windowOnScreen: false, mainScreen: nil, firstScreen: "first"),
            "first"
        )
        XCTAssertNil(
            QuitNotice.pickScreen(windowScreen: String?.none, windowOnScreen: false, mainScreen: nil, firstScreen: nil)
        )
    }

    func testTheSlabIsChromiumsSize() {
        XCTAssertEqual(QuitNotice.width, 350)
        XCTAssertEqual(QuitNotice.height, 70)
    }

    /// After an early release the notice sits for a second, fades in ten steps
    /// over 200 ms, and is then taken down.
    func testTheNoticeLingersThenFadesInTenStepsAndIsDismissed() {
        let steps = QuitNotice.fadeSteps
        XCTAssertEqual(steps.map(\.afterMs), [1_000, 1_020, 1_040, 1_060, 1_080, 1_100, 1_120, 1_140, 1_160, 1_180])
        for (step, expected) in zip(steps, [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1, 0]) {
            XCTAssertEqual(step.alpha, expected, accuracy: 1e-9)
        }
        XCTAssertEqual(QuitNotice.dismissAfterMs, 1_200)
    }

    /// 2609.0018 — "retargeted": the guard holds at least one Quit item, and no
    /// item still carries the native `terminate:` that would bypass it.
    func testTheGuardOwnsQuitOnlyWhenNoNativeQuitItemIsLeft() {
        XCTAssertTrue(QuitNotice.guardOwnsQuit(guardedItems: 1, nativeItems: 0))
        XCTAssertTrue(QuitNotice.guardOwnsQuit(guardedItems: 2, nativeItems: 0))
        XCTAssertFalse(QuitNotice.guardOwnsQuit(guardedItems: 0, nativeItems: 0))
        XCTAssertFalse(QuitNotice.guardOwnsQuit(guardedItems: 1, nativeItems: 1))
        XCTAssertFalse(QuitNotice.guardOwnsQuit(guardedItems: 0, nativeItems: 1))
    }
}
