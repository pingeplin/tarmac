import XCTest
@testable import TarmacKit

/// 2606.0006: the border rule with `fresh` dropped from the border. The teal
/// ring marks the selected card; both `prime` and `fresh` are border-inert
/// (signalled outside the border — header tint/shadow for prime, halo +
/// `✚ now` meta for fresh), and dead outranks the ring.
///
/// Scenario IDs below are 2606.0006's (they supersede 2606.0005's S1–S10 labels
/// on this file); the extra tests past S5 are retained regression guards.
final class CardChromeTests: XCTestCase {
    // MARK: - Happy path

    /// S1 (the behaviour change): a fresh card that is not selected draws the
    /// plain line — NOT the old agent edge. It signals freshness only via its
    /// halo + `✚ now` meta, applied outside CardChrome.
    func testFreshNotSelectedIsPlain() {
        XCTAssertEqual(CardChrome.borderRole(CardChrome.State(fresh: true)), .plain)
    }

    /// S2 (2606.0005 regression guard): the selected card shows the teal ring.
    func testSelectedIsTheRing() {
        XCTAssertEqual(CardChrome.borderRole(CardChrome.State(selected: true)), .focus)
    }

    // MARK: - Edge cases

    /// S3: selection outranks fresh — fresh is inert on the border, so
    /// `fresh + selected` is the plain ring, not anything fresh-tinted.
    func testSelectedOutranksFresh() {
        XCTAssertEqual(CardChrome.borderRole(CardChrome.State(fresh: true, selected: true)), .focus)
    }

    /// S4: a dead card keeps its muted border even while selected.
    func testDeadSelectedIsMuted() {
        XCTAssertEqual(CardChrome.borderRole(CardChrome.State(dead: true, selected: true)), .muted)
    }

    // MARK: - S5: the invariant, exhaustive over all 16 states

    /// S5: for every one of the 2^4 input combinations, the resting role equals
    /// the role computed independently from the inputs. The expected side is
    /// derived from the booleans (never read back from `borderRole`), so the test
    /// cannot pass by mirroring the implementation. This one positive equality
    /// locks three things: (a) the teal ring shows exactly for a selected,
    /// non-dead card; (b) every state lands in `.muted`/`.focus`/`.plain`
    /// — none takes a removed or fresh-driven role; (c) `prime` and `fresh` are
    /// both border-inert, so toggling either changes nothing.
    func testInvariantExhaustiveOverAll16States() {
        for mask in 0..<16 {
            let s = CardChrome.State(
                dead:     mask & 0b0001 != 0,
                fresh:    mask & 0b0010 != 0,
                prime:    mask & 0b0100 != 0,
                selected: mask & 0b1000 != 0
            )

            // (a) the ring coincides with a selected, non-dead card.
            XCTAssertEqual(
                CardChrome.borderRole(s) == .focus, s.selected && !s.dead,
                "state \(s): the ring must coincide with a selected, non-dead card"
            )

            // (b) role-coverage — expected computed from inputs, so no state can
            // take a removed (e.g. the old fresh-driven) role.
            let expectedRole: CardChrome.BorderRole =
                s.dead ? .muted
                : s.selected ? .focus
                : .plain
            XCTAssertEqual(
                CardChrome.borderRole(s), expectedRole,
                "state \(s): borderRole must equal the role computed from the inputs"
            )

            // (c) prime and fresh are border-inert: forcing each off vs on (with
            // every other input held fixed) changes nothing.
            assertInert(s, "prime", \.prime)
            assertInert(s, "fresh", \.fresh)
        }
    }

    /// Asserts a single boolean input has zero effect on chrome: with all other
    /// inputs held at `s`, the field being `false` vs `true` yields the same
    /// `borderRole`.
    private func assertInert(
        _ s: CardChrome.State, _ name: String, _ field: WritableKeyPath<CardChrome.State, Bool>
    ) {
        var off = s; off[keyPath: field] = false
        var on = s;  on[keyPath: field] = true
        XCTAssertEqual(
            CardChrome.borderRole(off), CardChrome.borderRole(on),
            "state \(s): \(name) must not affect borderRole"
        )
    }

    // MARK: - Retained regression guards (2606.0005 coverage, still load-bearing)

    /// A selected live terminal (prime AND selected) draws the teal ring — prime
    /// never overrides it.
    func testPrimeAndSelectedIsTheRing() {
        XCTAssertEqual(CardChrome.borderRole(CardChrome.State(prime: true, selected: true)), .focus)
    }

    /// A prime terminal that is not selected (after click-away / board-switch)
    /// shows no ring — only header tint + shadow, applied outside CardChrome.
    func testPrimeButNotSelectedIsPlain() {
        XCTAssertEqual(CardChrome.borderRole(CardChrome.State(prime: true)), .plain)
    }

    /// An idle card (nothing set) is the plain line.
    func testIdleCardIsPlain() {
        XCTAssertEqual(CardChrome.borderRole(CardChrome.State()), .plain)
    }
}
