import CoreGraphics
import XCTest
@testable import TarmacKit

/// The order in which a web view takes a new size so that what shows is
/// always a frame its web process has drawn (#270): the size the content was
/// last fitted under, the content's own frame, the page's layout, and the
/// bounds that wait for WebKit's word. One resize is in flight at a time.
final class PresentedResizeTests: XCTestCase {
    private let small = CGSize(width: 539, height: 385)
    private let large = CGSize(width: 686, height: 490)

    private func fitted(at size: CGSize) -> PresentedResize {
        var resize = PresentedResize()
        XCTAssertEqual(resize.plan(content: .zero, target: size, deferrable: true), .now(relayout: false))
        return resize
    }

    func testTheFirstSizeAppliesNowSinceNothingIsOnScreenYet() {
        var resize = PresentedResize()
        XCTAssertEqual(resize.plan(content: .zero, target: large, deferrable: true), .now(relayout: false))
    }

    func testAShrinkSendsTheLayoutFirstAndLeavesTheBoundsAndTheFrameForThePresentation() {
        var resize = fitted(at: large)
        XCTAssertEqual(
            resize.plan(content: large, target: small, deferrable: true),
            .staged(generation: 1, steps: [.layout(small)])
        )
        XCTAssertEqual(resize.presented(1), .init(steps: [.bounds(small), .fit(small)], awaiting: nil))
    }

    /// The old bounds stretch the old frame over the card and clip the area
    /// the content gained, where WebKit has not drawn yet.
    func testAGrowHoldsTheFittedBoundsThenTakesTheFrameBeforeTheLayout() {
        var resize = fitted(at: small)
        XCTAssertEqual(
            resize.plan(content: small, target: large, deferrable: true),
            .staged(generation: 1, steps: [.bounds(small), .contentFrame(large), .layout(large)])
        )
        XCTAssertEqual(resize.presented(1), .init(steps: [.bounds(large), .fit(large)], awaiting: nil))
    }

    /// A card resize drags the bounds along with the frame before the host
    /// sees it, so only the content's frame says which way the size went.
    func testGrowOrShrinkIsDecidedAgainstTheContentFrame() {
        var resize = fitted(at: small)
        _ = resize.plan(content: small, target: large, deferrable: true)
        let between = CGSize(width: 600, height: 430)
        XCTAssertEqual(resize.plan(content: large, target: between, deferrable: true), .pending(steps: [.bounds(small)]))
        XCTAssertEqual(
            resize.presented(1),
            .init(steps: [.bounds(large), .fit(large), .layout(between)], awaiting: 2)
        )
    }

    func testAResizeThatWidensAndShortensNeverNarrowsTheContentBeforeThePresentation() {
        var resize = fitted(at: small)
        let wideShort = CGSize(width: 686, height: 300)
        XCTAssertEqual(
            resize.plan(content: small, target: wideShort, deferrable: true),
            .staged(generation: 1, steps: [.bounds(small), .contentFrame(CGSize(width: 686, height: 385)), .layout(wideShort)])
        )
        XCTAssertEqual(resize.presented(1), .init(steps: [.bounds(wideShort), .fit(wideShort)], awaiting: nil))
    }

    /// A grip drag sends a size every few milliseconds, faster than WebKit
    /// presents; superseding the waiting resize each time would leave the
    /// card stretched for the whole drag. So it follows at presentation pace.
    func testAResizeWhileOneWaitsWaitsBehindItAndIsStagedOnItsPresentation() {
        var resize = fitted(at: large)
        _ = resize.plan(content: large, target: small, deferrable: true)
        let smaller = CGSize(width: 400, height: 300)
        XCTAssertEqual(resize.plan(content: large, target: smaller, deferrable: true), .pending(steps: []))
        XCTAssertEqual(
            resize.presented(1),
            .init(steps: [.bounds(small), .fit(small), .layout(smaller)], awaiting: 2)
        )
        XCTAssertEqual(resize.presented(2), .init(steps: [.bounds(smaller), .fit(smaller)], awaiting: nil))
    }

    func testOnlyTheLatestSizeWaitingBehindIsStaged() {
        var resize = fitted(at: small)
        _ = resize.plan(content: small, target: large, deferrable: true)
        let larger = CGSize(width: 800, height: 600)
        let largest = CGSize(width: 900, height: 700)
        XCTAssertEqual(resize.plan(content: large, target: larger, deferrable: true), .pending(steps: [.bounds(small)]))
        XCTAssertEqual(resize.plan(content: large, target: largest, deferrable: true), .pending(steps: [.bounds(small)]))
        XCTAssertEqual(
            resize.presented(1),
            .init(steps: [.bounds(large), .fit(large), .bounds(large), .contentFrame(largest), .layout(largest)], awaiting: 2)
        )
    }

    /// A shrink tells the page its layout before the frame follows; a size
    /// back to the content's own before that presentation must tell it again.
    func testASizeBackToTheContentsAfterAShrinkTellsThePageItsLayoutAgain() {
        var resize = fitted(at: large)
        _ = resize.plan(content: large, target: small, deferrable: true)
        XCTAssertEqual(resize.plan(content: large, target: large, deferrable: true), .pending(steps: []))
        XCTAssertEqual(
            resize.presented(1),
            .init(steps: [.bounds(small), .fit(small), .bounds(small), .contentFrame(large), .layout(large)], awaiting: 2)
        )
    }

    func testASizeBackToTheContentsThatCannotWaitTellsThePageItsLayoutAgain() {
        var resize = fitted(at: large)
        _ = resize.plan(content: large, target: small, deferrable: true)
        XCTAssertEqual(resize.plan(content: large, target: large, deferrable: false), .now(relayout: true))
    }

    func testTheSizeTheWaitingResizeGoesToDropsTheOneBehindIt() {
        var resize = fitted(at: small)
        _ = resize.plan(content: small, target: large, deferrable: true)
        _ = resize.plan(content: large, target: CGSize(width: 800, height: 600), deferrable: true)
        XCTAssertEqual(resize.plan(content: large, target: large, deferrable: true), .pending(steps: [.bounds(small)]))
        XCTAssertEqual(resize.presented(1), .init(steps: [.bounds(large), .fit(large)], awaiting: nil))
    }

    /// A card resize drags the bounds with the frame while a grow waits;
    /// left there, they would show the card's backdrop past the content.
    func testWhileAGrowWaitsTheBoundsStayAtTheSizeLastPresented() {
        var resize = fitted(at: small)
        _ = resize.plan(content: small, target: large, deferrable: true)
        XCTAssertEqual(
            resize.plan(content: large, target: CGSize(width: 700, height: 500), deferrable: true),
            .pending(steps: [.bounds(small)])
        )
    }

    /// While a shrink waits the content keeps its old frame, so the dragged
    /// bounds crop it as before; past that frame they would show the card's
    /// backdrop, so they are held.
    func testWhileAShrinkWaitsASizePastTheContentHoldsTheBounds() {
        var resize = fitted(at: large)
        _ = resize.plan(content: large, target: small, deferrable: true)
        XCTAssertEqual(
            resize.plan(content: large, target: CGSize(width: 800, height: 600), deferrable: true),
            .pending(steps: [.bounds(large)])
        )
    }

    /// The presentation and the fallback timer both report; the later of the
    /// two finds nothing left to do.
    func testAPresentationAppliesOnce() {
        var resize = fitted(at: large)
        _ = resize.plan(content: large, target: small, deferrable: true)
        XCTAssertNotNil(resize.presented(1))
        XCTAssertNil(resize.presented(1))
    }

    func testAReportForAGenerationNotWaitingIsIgnored() {
        var resize = fitted(at: large)
        _ = resize.plan(content: large, target: small, deferrable: true)
        XCTAssertNil(resize.presented(2))
        XCTAssertNotNil(resize.presented(1))
    }

    func testAResizeThatCannotWaitAppliesNowAndDropsTheOnesWaiting() {
        var resize = fitted(at: large)
        _ = resize.plan(content: large, target: small, deferrable: true)
        _ = resize.plan(content: large, target: CGSize(width: 450, height: 320), deferrable: true)
        let smaller = CGSize(width: 400, height: 300)
        XCTAssertEqual(resize.plan(content: large, target: smaller, deferrable: false), .now(relayout: true))
        XCTAssertNil(resize.presented(1))
        XCTAssertEqual(resize.plan(content: smaller, target: large, deferrable: true),
                       .staged(generation: 2, steps: [.bounds(smaller), .contentFrame(large), .layout(large)]))
    }

    /// A frame moved onto whole device pixels is a few tenths of a point off
    /// its size; fitting it again to the size it has is not a resize.
    func testTheFittedSizeAgainAppliesNow() {
        var resize = fitted(at: large)
        let aligned = CGSize(width: large.width - 0.4, height: large.height + 0.3)
        XCTAssertEqual(resize.plan(content: aligned, target: large, deferrable: true), .now(relayout: false))
    }

    /// A grip drag moves the card by less than a point per event at most
    /// zooms; each of those is a resize WebKit has to draw.
    func testAStepOfLessThanAPointIsStillStaged() {
        var resize = fitted(at: large)
        let step = CGSize(width: large.width + 0.7, height: large.height + 0.5)
        XCTAssertEqual(
            resize.plan(content: large, target: step, deferrable: true),
            .staged(generation: 1, steps: [.bounds(large), .contentFrame(step), .layout(step)])
        )
    }

    func testAPresentedSizeIsTheOneTheNextGrowHolds() {
        var resize = fitted(at: small)
        _ = resize.plan(content: small, target: large, deferrable: true)
        _ = resize.presented(1)
        let larger = CGSize(width: 800, height: 600)
        XCTAssertEqual(
            resize.plan(content: large, target: larger, deferrable: true),
            .staged(generation: 2, steps: [.bounds(large), .contentFrame(larger), .layout(larger)])
        )
    }

    func testASizeAppliedNowIsTheOneTheNextGrowHolds() {
        var resize = fitted(at: small)
        XCTAssertEqual(resize.plan(content: small, target: large, deferrable: false), .now(relayout: true))
        let larger = CGSize(width: 800, height: 600)
        XCTAssertEqual(
            resize.plan(content: large, target: larger, deferrable: true),
            .staged(generation: 1, steps: [.bounds(large), .contentFrame(larger), .layout(larger)])
        )
    }
}
