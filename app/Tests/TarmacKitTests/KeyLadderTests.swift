import XCTest
@testable import TarmacKit

/// K1, K6–K9, K12–K14, K16: which keys the app takes before the focused view.
final class KeyLadderTests: XCTestCase {
    private typealias Facts = KeyLadder.Facts

    private let shift: UInt = 1 << 17
    private let control: UInt = 1 << 18
    private let option: UInt = 1 << 19
    private let command: UInt = 1 << 20
    private let numericPad: UInt = 1 << 21

    private func letter(_ c: Character, _ mods: UInt = 0) -> KeyPress {
        KeyPress(keyCode: 0, characters: String(c), charactersIgnoringModifiers: String(c), modifierFlags: mods)
    }

    private func named(_ keyCode: UInt16, _ mods: UInt = 0) -> KeyPress {
        KeyPress(keyCode: keyCode, characters: "", charactersIgnoringModifiers: "", modifierFlags: mods)
    }

    private func esc(_ mods: UInt = 0) -> KeyPress { named(53, mods) }
    private func enter(_ mods: UInt = 0) -> KeyPress { named(36, mods) }
    private func tab(_ mods: UInt = 0) -> KeyPress { named(48, mods) }

    private let toasts = EscLadder.Facts(toastsShowing: true)

    /// Every key the ladder would otherwise take.
    private var takenKeys: [KeyPress] {
        [letter("k", command), letter("w", command), letter("t", command), tab(option), enter(), esc()]
    }

    /// Facts under which each of `takenKeys` is taken.
    private let eager = Facts(keys: .host, hasFlyTarget: true, esc: EscLadder.Facts(toastsShowing: true))

    func testEveryTakenKeyIsTakenUnderTheEagerFacts() {
        for key in takenKeys {
            XCTAssertNotEqual(KeyLadder.decide(key, eager), .passThrough, "\(key)")
        }
    }

    // MARK: K1 — IME composition

    func testAComposingKeyBypassesEveryShortcut() {
        var facts = eager
        facts.composing = true
        for key in takenKeys {
            XCTAssertEqual(KeyLadder.decide(key, facts), .passThrough, "\(key)")
        }
    }

    // MARK: H11 — a borrowed card's document holds the keys

    func testTheHostTakesNothingWhileADocumentHoldsTheKeys() {
        var facts = eager
        facts.keys = .document
        facts.esc.cardBorrowed = true
        for key in takenKeys {
            XCTAssertEqual(KeyLadder.decide(key, facts), .passThrough, "\(key)")
        }
    }

    func testEscUnborrowsWhenTheHostHoldsTheKeysOfABorrowedCard() {
        let facts = Facts(keys: .host, esc: EscLadder.Facts(cardBorrowed: true))
        XCTAssertEqual(KeyLadder.decide(esc(), facts), .esc(.unborrow))
    }

    // MARK: K6 — ⌘K

    func testCommandKTogglesTheSwitcher() {
        XCTAssertEqual(KeyLadder.decide(letter("k", command), Facts()), .toggleSwitcher)
        XCTAssertEqual(KeyLadder.decide(letter("k", command), Facts(switcherOpen: true)), .toggleSwitcher)
    }

    func testCommandKAllowsShiftButNotOptionOrControl() {
        XCTAssertEqual(KeyLadder.decide(letter("K", command | shift), Facts()), .toggleSwitcher)
        XCTAssertEqual(KeyLadder.decide(letter("k", command | option), Facts()), .passThrough)
        XCTAssertEqual(KeyLadder.decide(letter("k", command | control), Facts()), .passThrough)
    }

    // MARK: K7 — ⌘W

    func testCommandWClosesTheSelectedCard() {
        XCTAssertEqual(KeyLadder.decide(letter("w", command), Facts()), .closeSelectedCard)
        XCTAssertEqual(KeyLadder.decide(letter("W", command | shift), Facts()), .closeSelectedCard)
    }

    /// X26: with the switcher open ⌘W is still the app's, so it never reaches
    /// the menu's Close Window.
    func testCommandWIsNotLeftToTheOpenSwitcher() {
        XCTAssertEqual(KeyLadder.decide(letter("w", command), Facts(switcherOpen: true)), .closeSelectedCard)
    }

    // MARK: K14 — the open switcher owns the keyboard

    func testTheOpenSwitcherOwnsEveryOtherKey() {
        var facts = eager
        facts.switcherOpen = true
        let keys = [letter("t", command), tab(option), enter(), esc(), letter("a"), letter("q", command)]
        for key in keys {
            XCTAssertEqual(KeyLadder.decide(key, facts), .switcherKey, "\(key)")
        }
    }

    // MARK: K9 — ⌥Tab

    func testOptionTabCyclesTerminals() {
        XCTAssertEqual(KeyLadder.decide(tab(option), Facts()), .cycleTerminals)
    }

    func testTabWithAnyOtherModifierIsNotTheCycle() {
        for mods in [0, option | shift, option | command, option | control, command, control] {
            XCTAssertEqual(KeyLadder.decide(tab(mods), Facts()), .passThrough, "\(mods)")
        }
    }

    // MARK: K8 — ⌘T

    func testCommandTOpensATerminal() {
        XCTAssertEqual(KeyLadder.decide(letter("t", command), Facts()), .newTerminal)
        XCTAssertEqual(KeyLadder.decide(letter("T", command | shift), Facts()), .newTerminal)
        XCTAssertEqual(KeyLadder.decide(letter("t", command | option), Facts()), .passThrough)
    }

    // MARK: K12 — Return

    func testReturnFliesToAnOffscreenSignalWhenNoTerminalHoldsTheKeys() {
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(keys: .host, hasFlyTarget: true)), .flyToSignal)
    }

    func testReturnBelongsToTheTerminalThatHoldsTheKeys() {
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(keys: .terminal, hasFlyTarget: true)), .passThrough)
    }

    func testReturnWithNowhereToFlyDoesNothing() {
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(keys: .host, hasFlyTarget: false)), .passThrough)
    }

    func testReturnAllowsShiftButNoOtherModifier() {
        let facts = Facts(keys: .host, hasFlyTarget: true)
        XCTAssertEqual(KeyLadder.decide(enter(shift), facts), .flyToSignal)
        for mods in [command, option, control] {
            XCTAssertEqual(KeyLadder.decide(enter(mods), facts), .passThrough, "\(mods)")
        }
    }

    func testKeypadEnterFliesToo() {
        XCTAssertEqual(KeyLadder.decide(named(76, numericPad), Facts(keys: .host, hasFlyTarget: true)), .flyToSignal)
    }

    // MARK: K13 — ESC

    func testEscTakesTheLadderRung() {
        XCTAssertEqual(KeyLadder.decide(esc(), Facts(esc: toasts)), .esc(.clearToasts))
        XCTAssertEqual(
            KeyLadder.decide(esc(), Facts(esc: EscLadder.Facts(hasFreshDoc: true, selectedIsDoc: true))),
            .esc(.clearFreshDocs)
        )
    }

    func testEscRunsTheLadderWhoeverHoldsTheKeys() {
        XCTAssertEqual(KeyLadder.decide(esc(), Facts(keys: .terminal, esc: toasts)), .esc(.clearToasts))
        XCTAssertEqual(KeyLadder.decide(esc(), Facts(keys: .host, esc: toasts)), .esc(.clearToasts))
    }

    /// The web handler compares the key alone.
    func testEscRunsTheLadderUnderAnyModifier() {
        for mods in [shift, option, control] {
            XCTAssertEqual(KeyLadder.decide(esc(mods), Facts(esc: toasts)), .esc(.clearToasts), "\(mods)")
        }
    }

    /// A selected terminal is not a rung: ESC reaches its program.
    func testEscWithNoRungReachesTheTerminal() {
        XCTAssertEqual(KeyLadder.decide(esc(), Facts()), .passThrough)
    }

    // MARK: K16 — nothing else

    func testNoOtherKeyIsTaken() {
        let keys = [
            letter("a"), letter("p", command), letter("c", command), letter("q", command), letter("0", command),
            letter("=", command), letter("-", command), letter("1", command), letter("e", command),
            letter("n", command), named(51, command), named(126), named(125), enter(command),
        ]
        let facts = Facts(keys: .host, hasFlyTarget: true)
        for key in keys {
            XCTAssertEqual(KeyLadder.decide(key, facts), .passThrough, "\(key)")
        }
    }
}
