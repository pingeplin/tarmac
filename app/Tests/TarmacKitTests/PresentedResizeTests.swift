import CoreGraphics
import XCTest
@testable import TarmacKit

/// The order in which a web view takes a new size so that what shows is
/// always a frame its web process has drawn (#270): the size the content was
/// last fitted under, the content's own frame, the page's layout, and the
/// bounds that wait for WebKit's word.
final class PresentedResizeTests: XCTestCase {
    private let small = CGSize(width: 539, height: 385)
    private let large = CGSize(width: 686, height: 490)

    private func fitted(at size: CGSize) -> PresentedResize {
        var resize = PresentedResize()
        XCTAssertEqual(resize.plan(content: .zero, target: size, deferrable: true), .now)
        return resize
    }

    func testTheFirstSizeAppliesNowSinceNothingIsOnScreenYet() {
        var resize = PresentedResize()
        XCTAssertEqual(resize.plan(content: .zero, target: large, deferrable: true), .now)
    }

    func testAShrinkSendsTheLayoutFirstAndLeavesTheBoundsAndTheFrameForThePresentation() {
        var resize = fitted(at: large)
        XCTAssertEqual(
            resize.plan(content: large, target: small, deferrable: true),
            .staged(generation: 1, steps: [.layout(small)])
        )
        XCTAssertEqual(resize.presented(1), [.bounds(small), .fit(small)])
    }

    /// The old bounds stretch the old frame over the card and clip the area
    /// the content gained, where WebKit has not drawn yet.
    func testAGrowHoldsTheFittedBoundsThenTakesTheFrameBeforeTheLayout() {
        var resize = fitted(at: small)
        XCTAssertEqual(
            resize.plan(content: small, target: large, deferrable: true),
            .staged(generation: 1, steps: [.bounds(small), .contentFrame(large), .layout(large)])
        )
        XCTAssertEqual(resize.presented(1), [.bounds(large), .fit(large)])
    }

    /// A card resize drags the bounds along with the frame before the host
    /// sees it, so only the content's frame says which way the size went.
    func testGrowOrShrinkIsDecidedAgainstTheContentFrame() {
        var resize = fitted(at: small)
        _ = resize.plan(content: small, target: large, deferrable: true)
        let between = CGSize(width: 600, height: 430)
        XCTAssertEqual(
            resize.plan(content: large, target: between, deferrable: true),
            .staged(generation: 2, steps: [.layout(between)])
        )
    }

    func testAResizeThatWidensAndShortensNeverNarrowsTheContentBeforeThePresentation() {
        var resize = fitted(at: small)
        let wideShort = CGSize(width: 686, height: 300)
        XCTAssertEqual(
            resize.plan(content: small, target: wideShort, deferrable: true),
            .staged(generation: 1, steps: [.bounds(small), .contentFrame(CGSize(width: 686, height: 385)), .layout(wideShort)])
        )
        XCTAssertEqual(resize.presented(1), [.bounds(wideShort), .fit(wideShort)])
    }

    func testANewerResizeMakesTheOlderGenerationStale() {
        var resize = fitted(at: large)
        _ = resize.plan(content: large, target: small, deferrable: true)
        let smaller = CGSize(width: 400, height: 300)
        XCTAssertEqual(
            resize.plan(content: large, target: smaller, deferrable: true),
            .staged(generation: 2, steps: [.layout(smaller)])
        )
        XCTAssertNil(resize.presented(1))
        XCTAssertEqual(resize.presented(2), [.bounds(smaller), .fit(smaller)])
    }

    /// The presentation and the fallback timer both report; the later of the
    /// two finds nothing left to do.
    func testAPresentationAppliesOnce() {
        var resize = fitted(at: large)
        _ = resize.plan(content: large, target: small, deferrable: true)
        XCTAssertNotNil(resize.presented(1))
        XCTAssertNil(resize.presented(1))
    }

    func testAResizeThatCannotWaitAppliesNowAndDropsTheOneWaiting() {
        var resize = fitted(at: large)
        _ = resize.plan(content: large, target: small, deferrable: true)
        let smaller = CGSize(width: 400, height: 300)
        XCTAssertEqual(resize.plan(content: large, target: smaller, deferrable: false), .now)
        XCTAssertNil(resize.presented(1))
    }

    /// A frame moved onto whole device pixels is a few tenths of a point off
    /// its size; that is not a resize WebKit has to draw.
    func testASizeWithinAPointOfTheContentAppliesNow() {
        var resize = fitted(at: large)
        let aligned = CGSize(width: large.width - 0.4, height: large.height + 0.3)
        XCTAssertEqual(resize.plan(content: aligned, target: large, deferrable: true), .now)
    }

    func testTheSizeAWaitingResizeGoesToKeepsItWaiting() {
        var resize = fitted(at: small)
        _ = resize.plan(content: small, target: large, deferrable: true)
        XCTAssertEqual(resize.plan(content: large, target: large, deferrable: true), .pending)
        XCTAssertEqual(resize.presented(1), [.bounds(large), .fit(large)])
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
        XCTAssertEqual(resize.plan(content: small, target: large, deferrable: false), .now)
        let larger = CGSize(width: 800, height: 600)
        XCTAssertEqual(
            resize.plan(content: large, target: larger, deferrable: true),
            .staged(generation: 1, steps: [.bounds(large), .contentFrame(larger), .layout(larger)])
        )
    }
}
