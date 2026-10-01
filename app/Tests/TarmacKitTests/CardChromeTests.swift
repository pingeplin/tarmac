import XCTest
@testable import TarmacKit

/// 2606.0006: the active-card chrome rule with `fresh` dropped from the border.
/// The teal ring + handles still mark an active card (focused OR selected); both
/// `prime` and `fresh` are now border-inert (signalled outside the border —
/// header tint/shadow for prime, halo + `✚ now` meta for fresh), and dead stays
/// the one divergence (muted border yet handles for resize).
///
/// Scenario IDs below are 2606.0006's (they supersede 2606.0005's S1–S10 labels
/// on this file); the extra tests past S5 are retained regression guards.
final class CardChromeTests: XCTestCase {
    // MARK: - Happy path

    /// S1 (the behaviour change): a fresh-but-not-active card draws the plain
    /// line — NOT the old agent edge — and shows no handles. It signals freshness
    /// only via its halo + `✚ now` meta, applied outside CardChrome.
    func testFreshNotActiveIsPlainNoHandles() {
        let s = CardChrome.State(fresh: true)
        XCTAssertEqual(CardChrome.borderRole(s), .plain)
        XCTAssertFalse(CardChrome.showsHandles(s))
    }

    /// S2 (2606.0005 regression guard): a single-clicked card (focused) shows the
    /// teal ring AND handles.
    func testFocusedIsActiveRingWithHandles() {
        let s = CardChrome.State(focused: true)
        XCTAssertEqual(CardChrome.borderRole(s), .focus)
        XCTAssertTrue(CardChrome.showsHandles(s))
    }

    // MARK: - Edge cases

    /// S3: an active card outranks fresh — fresh is inert on the border, so
    /// `fresh + focused` is the plain active ring, not anything fresh-tinted.
    func testActiveOutranksFresh() {
        let s = CardChrome.State(fresh: true, focused: true)
        XCTAssertEqual(CardChrome.borderRole(s), .focus)
        XCTAssertTrue(CardChrome.showsHandles(s))
    }

    /// S4: a dead card resized via a header grab — muted border yet handles
    /// present (the one allowed divergence from the ring⟺handles invariant).
    func testDeadSelectedIsMutedButShowsHandles() {
        let s = CardChrome.State(dead: true, selected: true)
        XCTAssertEqual(CardChrome.borderRole(s), .muted)
        XCTAssertTrue(CardChrome.showsHandles(s))
    }

    // MARK: - S5: the invariant, exhaustive over all 32 states

    /// S5: for every one of the 2^5 input combinations, the resting role equals
    /// the role computed independently from the inputs. The expected side is
    /// derived from the booleans (never read back from `borderRole`), so the test
    /// cannot pass by mirroring the implementation. This one positive equality
    /// locks three things: (a) the teal ring shows exactly for an active,
    /// non-dead card; (b) every state lands in `.muted`/`.focus`/`.plain`
    /// — none takes a removed or fresh-driven role; (c) `prime` and `fresh` are
    /// both border-inert, so toggling either changes neither role nor handles.
    func testInvariantExhaustiveOverAll32States() {
        for mask in 0..<32 {
            let s = CardChrome.State(
                dead:     mask & 0b00001 != 0,
                fresh:    mask & 0b00010 != 0,
                prime:    mask & 0b00100 != 0,
                focused:  mask & 0b01000 != 0,
                selected: mask & 0b10000 != 0
            )

            // (a) the focus ring coincides with an active, non-dead card.
            let expectFocusRing = (s.focused || s.selected) && !s.dead
            XCTAssertEqual(
                CardChrome.borderRole(s) == .focus, expectFocusRing,
                "state \(s): the focus ring must coincide with an active, non-dead card"
            )

            // (b) role-coverage — expected computed from inputs, so no state can
            // take a removed (e.g. the old fresh-driven) role.
            let expectedRole: CardChrome.BorderRole =
                s.dead ? .muted
                : (s.focused || s.selected) ? .focus
                : .plain
            XCTAssertEqual(
                CardChrome.borderRole(s), expectedRole,
                "state \(s): borderRole must equal the role computed from the inputs"
            )

            // (c) prime and fresh are border-inert: forcing each off vs on (with
            // every other input held fixed) changes neither role nor handles.
            assertInert(s, "prime", \.prime)
            assertInert(s, "fresh", \.fresh)
        }
    }

    /// Asserts a single boolean input has zero effect on chrome: with all other
    /// inputs held at `s`, the field being `false` vs `true` yields the same
    /// `borderRole` and `showsHandles`.
    private func assertInert(
        _ s: CardChrome.State, _ name: String, _ field: WritableKeyPath<CardChrome.State, Bool>
    ) {
        var off = s; off[keyPath: field] = false
        var on = s;  on[keyPath: field] = true
        XCTAssertEqual(
            CardChrome.borderRole(off), CardChrome.borderRole(on),
            "state \(s): \(name) must not affect borderRole"
        )
        XCTAssertEqual(
            CardChrome.showsHandles(off), CardChrome.showsHandles(on),
            "state \(s): \(name) must not affect handle visibility"
        )
    }

    // MARK: - Retained regression guards (2606.0005 coverage, still load-bearing)

    /// A header-grab (selected, not focused) looks identical to a click — the
    /// unified ring + handles.
    func testSelectedLooksLikeFocused() {
        let s = CardChrome.State(selected: true)
        XCTAssertEqual(CardChrome.borderRole(s), .focus)
        XCTAssertTrue(CardChrome.showsHandles(s))
    }

    /// A clicked live terminal (prime AND focused) draws the teal ring — prime
    /// never overrides it.
    func testPrimeAndFocusedIsFocus() {
        let s = CardChrome.State(prime: true, focused: true)
        XCTAssertEqual(CardChrome.borderRole(s), .focus)
        XCTAssertTrue(CardChrome.showsHandles(s))
    }

    /// A prime-but-not-active terminal (after click-away / board-switch) shows no
    /// ring and no handles — only header tint + shadow, applied outside CardChrome.
    func testPrimeButNotActiveIsPlainNoHandles() {
        let s = CardChrome.State(prime: true, focused: false, selected: false)
        XCTAssertEqual(CardChrome.borderRole(s), .plain)
        XCTAssertFalse(CardChrome.showsHandles(s))
    }

    /// An idle card (nothing set) is the plain line with no handles.
    func testIdleCardIsPlainNoHandles() {
        let s = CardChrome.State()
        XCTAssertEqual(CardChrome.borderRole(s), .plain)
        XCTAssertFalse(CardChrome.showsHandles(s))
    }
}
