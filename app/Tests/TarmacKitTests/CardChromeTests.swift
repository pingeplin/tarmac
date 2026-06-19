import XCTest
@testable import TarmacKit

/// 2606.0005: the unified active-card chrome rule — one teal ring + handles for
/// an active card (focused OR selected), `prime` inert on the border, dead/
/// detached the only divergence (muted border yet handles for resize).
final class CardChromeTests: XCTestCase {
    // MARK: - Happy path

    /// S1: a single-clicked card (focused) shows the teal ring AND handles.
    func testFocusedIsActiveRingWithHandles() {
        let s = CardChrome.State(focused: true)
        XCTAssertEqual(CardChrome.borderRole(s), .focus)
        XCTAssertTrue(CardChrome.showsHandles(s))
    }

    /// S2: a header-grab (selected, not focused) looks identical to a click —
    /// the unified ring, NOT the old agent colour.
    func testSelectedLooksLikeFocusedNotAgent() {
        let s = CardChrome.State(selected: true)
        XCTAssertEqual(CardChrome.borderRole(s), .focus)
        XCTAssertNotEqual(CardChrome.borderRole(s), .agent)
        XCTAssertTrue(CardChrome.showsHandles(s))
    }

    /// S3: a clicked live terminal (prime AND focused) draws the teal ring —
    /// prime no longer overrides it with the lift border.
    func testPrimeAndFocusedIsFocusNotPrimeBorder() {
        let s = CardChrome.State(prime: true, focused: true)
        XCTAssertEqual(CardChrome.borderRole(s), .focus)
        XCTAssertTrue(CardChrome.showsHandles(s))
    }

    // MARK: - Edge cases

    /// S4: a prime-but-not-active terminal (after click-away / board-switch)
    /// shows no ring and no handles — only header tint + shadow, applied
    /// outside CardChrome.
    func testPrimeButNotActiveHasNoRingNoHandles() {
        let s = CardChrome.State(prime: true, focused: false, selected: false)
        XCTAssertEqual(CardChrome.borderRole(s), .plain)
        XCTAssertFalse(CardChrome.showsHandles(s))
    }

    /// S5: a fresh-but-not-active card shows the agent halo and no handles.
    func testFreshNotActiveIsAgentHaloNoHandles() {
        let s = CardChrome.State(fresh: true)
        XCTAssertEqual(CardChrome.borderRole(s), .agent)
        XCTAssertFalse(CardChrome.showsHandles(s))
    }

    /// S6: an active card outranks the fresh halo (the app also clears `fresh`
    /// on focus, so this state is transient — this pins the priority).
    func testActiveOutranksFresh() {
        let s = CardChrome.State(fresh: true, focused: true)
        XCTAssertEqual(CardChrome.borderRole(s), .focus)
        XCTAssertTrue(CardChrome.showsHandles(s))
    }

    /// S7: an idle card (nothing set) is the plain line with no handles.
    func testIdleCardIsPlainNoHandles() {
        let s = CardChrome.State()
        XCTAssertEqual(CardChrome.borderRole(s), .plain)
        XCTAssertFalse(CardChrome.showsHandles(s))
    }

    // MARK: - The dead/detached exception

    /// S8: a dead card resized via a header grab — muted border yet handles
    /// present (the one allowed divergence from the ring⟺handles invariant).
    func testDeadSelectedIsMutedButShowsHandles() {
        let s = CardChrome.State(dead: true, selected: true)
        XCTAssertEqual(CardChrome.borderRole(s), .muted)
        XCTAssertTrue(CardChrome.showsHandles(s))
    }

    /// S9: detached is an exception alongside dead.
    func testDetachedSelectedIsMutedButShowsHandles() {
        let s = CardChrome.State(detached: true, selected: true)
        XCTAssertEqual(CardChrome.borderRole(s), .muted)
        XCTAssertTrue(CardChrome.showsHandles(s))
    }

    // MARK: - S10: the invariant, exhaustive over all 64 states

    /// For every one of the 2^6 input combinations, the teal ring shows exactly
    /// for an active card that is neither dead nor detached. The expected side is
    /// computed independently of `borderRole`'s priority chain (so the test can't
    /// pass by mirroring the implementation), and flipping only `prime` must
    /// never change the outcome — proving prime is inert on the chrome.
    func testFocusRingCoincidesWithHandlesAcrossAll64States() {
        for mask in 0..<64 {
            let s = CardChrome.State(
                dead:     mask & 0b000001 != 0,
                detached: mask & 0b000010 != 0,
                fresh:    mask & 0b000100 != 0,
                prime:    mask & 0b001000 != 0,
                focused:  mask & 0b010000 != 0,
                selected: mask & 0b100000 != 0
            )

            let expectFocusRing = (s.focused || s.selected) && !s.dead && !s.detached
            XCTAssertEqual(
                CardChrome.borderRole(s) == .focus, expectFocusRing,
                "state \(s): the focus ring must coincide with an active, non-dead/detached card"
            )

            var withoutPrime = s
            withoutPrime.prime = false
            XCTAssertEqual(
                CardChrome.borderRole(s), CardChrome.borderRole(withoutPrime),
                "state \(s): prime must not affect borderRole"
            )
            XCTAssertEqual(
                CardChrome.showsHandles(s), CardChrome.showsHandles(withoutPrime),
                "state \(s): prime must not affect handle visibility"
            )
        }
    }
}
