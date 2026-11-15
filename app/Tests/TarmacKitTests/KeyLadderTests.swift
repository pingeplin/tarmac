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
        [
            letter("k", command), letter("i", command), letter("w", command), letter("t", command), enter(), esc(),
        ]
    }

    /// Facts under which each of `takenKeys` is taken.
    private let eager = Facts(
        keys: .host, hasFlyTarget: true, esc: EscLadder.Facts(toastsShowing: true, selectedIsDoc: true)
    )

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

    // MARK: D17, X30 — ⌘C

    /// A doc's web view holds its own selection and answers the menu's Copy,
    /// so ⌘C is the focused view's whatever is selected.
    func testCommandCIsNeverTheLadders() {
        let docSelected = Facts(keys: .host, esc: EscLadder.Facts(selectedIsDoc: true))
        XCTAssertEqual(KeyLadder.decide(letter("c", command), docSelected), .passThrough)
        XCTAssertEqual(KeyLadder.decide(letter("c", command), Facts()), .passThrough)
    }

    // MARK: K9 — Tab

    /// Tab goes to whoever has the keyboard: ⌥Tab is a terminal's Meta-Tab.
    func testTabIsNeverTheAppsKeyWhateverTheModifiers() {
        for mods in [0, option, option | shift, option | command, option | control, command, control] {
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

    /// A markdown doc's raw HTML can hold a textarea or an input. Return typed
    /// there is the control's, as it is in the web app.
    func testReturnBelongsToATextControlThatHoldsTheKeys() {
        let typing = Facts(keys: .host, editingText: true, hasFlyTarget: true)
        XCTAssertEqual(KeyLadder.decide(enter(), typing), .passThrough)
        XCTAssertEqual(KeyLadder.decide(named(76, numericPad), typing), .passThrough)
    }

    /// Only Return is the control's: the app's other keys work from there.
    func testEveryOtherAppKeyIsStillTakenFromATextControl() {
        var facts = eager
        facts.editingText = true
        for key in [letter("k", command), letter("w", command), letter("t", command), esc()] {
            XCTAssertNotEqual(KeyLadder.decide(key, facts), .passThrough, "\(key)")
        }
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

    // MARK: - the inbox (2611.0013 S7)

    func testS7CommandITogglesTheInboxWhoeverHoldsTheKeysAndOverTheSwitcher() {
        for keys in [KeyLadder.Keys.terminal, .host, .console] {
            XCTAssertEqual(KeyLadder.decide(letter("i", command), Facts(keys: keys)), .toggleInbox, "\(keys)")
        }
        XCTAssertEqual(KeyLadder.decide(letter("i", command), Facts(switcherOpen: true)), .toggleInbox)
        XCTAssertEqual(KeyLadder.decide(letter("i", command), Facts(inboxOpen: true)), .toggleInbox)
    }

    func testS7TheOpenInboxOwnsEveryKeyButCommandKAndCommandW() {
        let open = Facts(keys: .host, hasFlyTarget: true, esc: toasts, inboxOpen: true)
        for key in [enter(), esc(), letter("a"), named(125), tab(), letter("v", command)] {
            XCTAssertEqual(KeyLadder.decide(key, open), .inboxKey, "\(key)")
        }
        XCTAssertEqual(KeyLadder.decide(letter("k", command), open), .toggleSwitcher)
        XCTAssertEqual(KeyLadder.decide(letter("w", command), open), .closeSelectedCard)
        XCTAssertEqual(KeyLadder.decide(letter("t", command), open), .inboxKey)
    }

    func testS7PlainReturnWithTheInboxOpenIsTheInboxsNotAFlight() {
        let facts = Facts(keys: .host, hasFlyTarget: true)
        XCTAssertEqual(KeyLadder.decide(enter(), facts), .flyToSignal)
        var open = facts
        open.inboxOpen = true
        XCTAssertEqual(KeyLadder.decide(enter(), open), .inboxKey)
    }

    func testTheRestoreCardTakesCommandIBeforeTheInbox() {
        XCTAssertEqual(KeyLadder.decide(letter("i", command), Facts(restoreCard: [], inboxOpen: true)), .restoreCard(.perCard))
    }

    // MARK: - the console of an HTML card

    private let left: UInt16 = 123
    private let right: UInt16 = 124
    private let down: UInt16 = 125
    private let up: UInt16 = 126
    private let backspace: UInt16 = 51

    /// A press in an HTML card's console gives its text the keyboard, so that
    /// it can be selected and copied. It takes no typing, and what is typed
    /// next is not lost: it goes back to where typing goes.
    func testTypingWithTheConsoleFocusedGoesBackToWhereTypingGoes() {
        let typed = [
            letter("a"), letter("A", shift), letter(" "), letter("c", control), letter("å", option), enter(),
            enter(shift), tab(), named(backspace), named(up), named(down), named(left), named(right),
        ]
        for press in typed {
            XCTAssertEqual(KeyLadder.decide(press, Facts(keys: .console)), .returnKeys, "\(press)")
        }
    }

    /// ⌘C and ⌘A are the menu's, sent to the text; a shifted arrow, home,
    /// end or page key stretches the selection.
    func testTheConsoleKeepsTheKeysThatCopyAndSelect() {
        let kept = [
            letter("c", command), letter("a", command), letter("f", command), named(left, shift), named(right, shift),
            named(up, shift), named(down, shift), named(115, shift), named(119, shift), named(116, shift),
            named(121, shift), named(right, shift | option), named(left, command | shift),
        ]
        for press in kept {
            XCTAssertEqual(KeyLadder.decide(press, Facts(keys: .console)), .passThrough, "\(press)")
        }
    }

    func testAShiftedKeyThatMovesNothingIsTyping() {
        XCTAssertEqual(KeyLadder.decide(named(backspace, shift), Facts(keys: .console)), .returnKeys)
        XCTAssertEqual(KeyLadder.decide(tab(shift), Facts(keys: .console)), .returnKeys)
    }

    func testTheAppsOwnKeysAreTakenFromTheConsoleAsFromAnywhere() {
        let facts = Facts(keys: .console)
        XCTAssertEqual(KeyLadder.decide(letter("k", command), facts), .toggleSwitcher)
        XCTAssertEqual(KeyLadder.decide(letter("w", command), facts), .closeSelectedCard)
        XCTAssertEqual(KeyLadder.decide(letter("t", command), facts), .newTerminal)
        XCTAssertEqual(KeyLadder.decide(letter("a"), Facts(switcherOpen: true, keys: .console)), .switcherKey)
    }

    /// No terminal holds the keys, so Return flies as it does from the board.
    func testReturnFliesFromTheConsoleWhenThereIsSomewhereToFly() {
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(keys: .console, hasFlyTarget: true)), .flyToSignal)
    }

    func testEscClimbsTheLadderFromTheConsoleAndIsTypingOnlyPastItsLastRung() {
        let borrowed = Facts(keys: .console, esc: EscLadder.Facts(cardBorrowed: true))
        XCTAssertEqual(KeyLadder.decide(esc(), borrowed), .esc(.unborrow))
        XCTAssertEqual(KeyLadder.decide(esc(), Facts(keys: .console)), .returnKeys)
    }

    func testKeysAreReturnedFromNowhereElse() {
        for keys in [KeyLadder.Keys.terminal, .host, .document] {
            XCTAssertEqual(KeyLadder.decide(letter("a"), Facts(keys: keys)), .passThrough, "\(keys)")
        }
    }

    /// The web handler compares the key alone, ⌘ included.
    func testCommandEscRunsTheLadder() {
        XCTAssertEqual(KeyLadder.decide(esc(command), Facts(esc: toasts)), .esc(.clearToasts))
    }

    func testCapsLockDoesNotStopAnAppKey() {
        XCTAssertEqual(KeyLadder.decide(letter("t", command | 1 << 16), Facts()), .newTerminal)
    }

    // MARK: - 2611.0011 S9: Return on a resume or a reopen offer

    private func repeated(_ press: KeyPress) -> KeyPress {
        var press = press
        press.isRepeat = true
        return press
    }

    func testS9PlainReturnRunsAnArmedResumeOrReopensADeadCard() {
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(offer: .resumeArmed)), .runResume)
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(offer: .reopen)), .reopenDead)
    }

    func testS9TheKeysThatComeFirstStillComeFirst() {
        var composing = Facts(offer: .resumeArmed)
        composing.composing = true
        XCTAssertNotEqual(KeyLadder.decide(enter(), composing), .runResume)
        var switcher = Facts(offer: .resumeArmed)
        switcher.switcherOpen = true
        XCTAssertNotEqual(KeyLadder.decide(enter(), switcher), .runResume)
        for mods in [option, command, control] {
            XCTAssertNotEqual(KeyLadder.decide(enter(mods), Facts(offer: .resumeArmed)), .runResume, "\(mods)")
            XCTAssertNotEqual(KeyLadder.decide(enter(mods), Facts(offer: .reopen)), .reopenDead, "\(mods)")
        }
        XCTAssertNotEqual(KeyLadder.decide(enter(), Facts(keys: .host, offer: .resumeArmed)), .runResume)
    }

    /// A fresh Return on an offer that is not armed reaches the shell, and
    /// so drops the offer (D9).
    func testS9AFreshReturnOnAnOfferThatIsNotArmedPassesThrough() {
        XCTAssertEqual(KeyLadder.decide(enter(), Facts()), .passThrough)
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(offer: .resumeIdle)), .passThrough)
    }

    func testS9ARepeatedReturnOnAReopenOfferIsIgnored() {
        XCTAssertEqual(KeyLadder.decide(repeated(enter()), Facts(offer: .reopen)), .swallow)
    }

    /// The D10 amendment: a held Return reopens once, and its repeats neither
    /// run the new card's command nor reach its shell.
    func testS9AHeldReturnReopensOnceAndItsRepeatsAreIgnored() {
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(offer: .reopen)), .reopenDead)
        XCTAssertEqual(KeyLadder.decide(repeated(enter()), Facts(offer: .resumeArmed)), .swallow)
        XCTAssertEqual(KeyLadder.decide(repeated(enter()), Facts(offer: .resumeIdle)), .swallow)
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(offer: .resumeArmed)), .runResume)
        XCTAssertEqual(KeyLadder.decide(repeated(enter()), Facts()), .passThrough)
    }

    /// RA3: a held Return that runs the command sends it once.
    func testS9AHeldReturnThatRanTheCommandIgnoresItsRepeats() {
        let runReturn = enter()
        XCTAssertTrue(KeyLadder.afterRun(was: false, press: runReturn, action: .runResume))
        XCTAssertEqual(KeyLadder.decide(repeated(enter()), Facts(afterRun: true)), .swallow)
        XCTAssertTrue(KeyLadder.afterRun(was: true, press: repeated(enter()), action: .swallow))
        XCTAssertFalse(KeyLadder.afterRun(was: true, press: letter("a"), action: .passThrough))
    }

    func testS9AFreshReturnAfterTheRunPassesThroughAndClearsTheLatch() {
        let action = KeyLadder.decide(enter(), Facts(afterRun: true))
        XCTAssertEqual(action, .passThrough)
        XCTAssertFalse(KeyLadder.afterRun(was: true, press: enter(), action: action))
    }

    func testARepeatedLetterUnderTheLatchKeepsItAndPassesThrough() {
        XCTAssertEqual(KeyLadder.decide(repeated(letter("a")), Facts(afterRun: true)), .passThrough)
        XCTAssertTrue(KeyLadder.afterRun(was: true, press: repeated(letter("a")), action: .passThrough))
    }

    // MARK: - 2611.0011 S27: Esc meets the toast first (a guard; it passed before)

    func testS27EscClearsTheToastBeforeItReachesTheTerminalAndPassesThroughWithNoRung() {
        XCTAssertEqual(KeyLadder.decide(esc(), Facts(keys: .terminal, esc: toasts)), .esc(.clearToasts))
        XCTAssertEqual(KeyLadder.decide(esc(), Facts(keys: .terminal, esc: EscLadder.Facts())), .passThrough)
    }

    // MARK: - #358: the restore card takes the first key

    private let cardUp = Facts(restoreCard: [])

    func testAnyKeyClosesTheRestoreCardAndReachesNothingElse() {
        let keys = [letter("a"), letter("a", control), enter(), esc(), tab(), letter("k", command), letter("v", command)]
        for key in keys {
            XCTAssertEqual(KeyLadder.decide(key, cardUp), .restoreCard(.perCard), "\(key)")
        }
    }

    /// R4: the card takes the first key before the resume panels.
    func testTheCardTakesReturnBeforeAnArmedResumeOrAReopen() {
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(offer: .resumeArmed, restoreCard: [])), .restoreCard(.perCard))
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(offer: .reopen, restoreCard: [])), .restoreCard(.perCard))
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(offer: .resumeArmed)), .runResume)
    }

    func testTheCardTakesEscBeforeTheEscLadder() {
        XCTAssertEqual(KeyLadder.decide(esc(), Facts(esc: toasts, restoreCard: [])), .restoreCard(.perCard))
    }

    func testTheCardComesBeforeTheSwitcherAndAnyFocus() {
        var facts = eager
        facts.switcherOpen = true
        facts.restoreCard = []
        XCTAssertEqual(KeyLadder.decide(letter("a"), facts), .restoreCard(.perCard))
        XCTAssertEqual(KeyLadder.decide(letter("a"), Facts(keys: .document, restoreCard: [])), .restoreCard(.perCard))
    }

    func testTheCardTakesTheKeyBeforeAComposition() {
        XCTAssertEqual(KeyLadder.decide(letter("a"), Facts(composing: true, restoreCard: [])), .restoreCard(.perCard))
    }

    /// A repeat dropped while the card is up, from a key held since before it
    /// showed, does not set the latch: only closing the card does.
    func testADroppedRepeatDoesNotSetTheLatch() {
        XCTAssertFalse(KeyLadder.afterRestoreCard(was: false, press: repeated(letter("a")), action: .swallow))
    }

    /// ⌘Q is the menu's: Quit and its hold guard still work with the card up.
    func testCommandQPassesThroughTheCard() {
        XCTAssertEqual(KeyLadder.decide(letter("q", command), cardUp), .passThrough)
    }

    /// A key held since before the card showed does not close it unseen.
    func testARepeatDoesNotCloseTheCard() {
        XCTAssertEqual(KeyLadder.decide(repeated(letter("a")), cardUp), .swallow)
    }

    /// The key that closed the card reaches no terminal while it is held.
    func testTheRepeatsOfTheKeyThatClosedTheCardAreIgnored() {
        XCTAssertTrue(KeyLadder.afterRestoreCard(was: false, press: enter(), action: .restoreCard(.perCard)))
        XCTAssertEqual(KeyLadder.decide(repeated(enter()), Facts(afterRestoreCard: true)), .swallow)
        XCTAssertEqual(KeyLadder.decide(repeated(letter("a")), Facts(afterRestoreCard: true)), .swallow)
        XCTAssertTrue(KeyLadder.afterRestoreCard(was: true, press: repeated(enter()), action: .swallow))
    }

    func testAFreshKeyAfterTheCardIsDecidedAsUsualAndClearsTheLatch() {
        let action = KeyLadder.decide(enter(), Facts(offer: .resumeArmed, afterRestoreCard: true))
        XCTAssertEqual(action, .runResume)
        XCTAssertFalse(KeyLadder.afterRestoreCard(was: true, press: enter(), action: action))
        XCTAssertFalse(KeyLadder.afterRestoreCard(was: false, press: repeated(enter()), action: .passThrough))
    }

    // MARK: - 2611.0015 S3: the restore card's keys with choices

    private let choicesUp = Facts(restoreCard: [.resumeAll, .perCard, .skipAll])

    func testS3PlainOrShiftedReturnResumesAll() {
        XCTAssertEqual(KeyLadder.decide(enter(), choicesUp), .restoreCard(.resumeAll))
        XCTAssertEqual(KeyLadder.decide(enter(shift), choicesUp), .restoreCard(.resumeAll))
    }

    func testS3PlainOrShiftedEscSkipsAllAndDoesNotClearTheToastsFirst() {
        XCTAssertEqual(KeyLadder.decide(esc(), choicesUp), .restoreCard(.skipAll))
        XCTAssertEqual(KeyLadder.decide(esc(shift), choicesUp), .restoreCard(.skipAll))
        XCTAssertEqual(KeyLadder.decide(esc(), Facts(esc: toasts, restoreCard: [.resumeAll, .perCard, .skipAll])), .restoreCard(.skipAll))
    }

    func testS3AnyOtherKeyDecidesPerCard() {
        let keys = [
            letter("a"), letter("a", control), tab(), letter("k", command), letter("v", command),
            enter(option), enter(command), enter(control), esc(command), esc(option),
        ]
        for key in keys {
            XCTAssertEqual(KeyLadder.decide(key, choicesUp), .restoreCard(.perCard), "\(key)")
        }
    }

    func testS3CommandQPassesThroughAndARepeatNeverChooses() {
        XCTAssertEqual(KeyLadder.decide(letter("q", command), choicesUp), .passThrough)
        for key in [enter(), esc(), letter("a")] {
            XCTAssertEqual(KeyLadder.decide(repeated(key), choicesUp), .swallow, "\(key)")
        }
    }

    func testS3TheCardTakesReturnBeforeEveryOtherRung() {
        var composing = choicesUp
        composing.composing = true
        var switcher = choicesUp
        switcher.switcherOpen = true
        var inbox = choicesUp
        inbox.inboxOpen = true
        var document = choicesUp
        document.keys = .document
        var armed = choicesUp
        armed.offer = .resumeArmed
        for facts in [composing, switcher, inbox, document, armed] {
            XCTAssertEqual(KeyLadder.decide(enter(), facts), .restoreCard(.resumeAll), "\(facts)")
        }
    }

    // MARK: - 2611.0015 S4: the latch covers all three choices

    func testS4ResumeAllAndSkipAllSetTheLatch() {
        XCTAssertTrue(KeyLadder.afterRestoreCard(was: false, press: enter(), action: .restoreCard(.resumeAll)))
        XCTAssertTrue(KeyLadder.afterRestoreCard(was: false, press: esc(), action: .restoreCard(.skipAll)))
    }

    /// The prime card ran at once, so it has no offer and no `afterRun`:
    /// only the latch keeps the repeats from its shell.
    func testS4UnderTheLatchTheRepeatsReachNoTerminal() {
        let latched = Facts(offer: .none, afterRun: false, afterRestoreCard: true)
        XCTAssertEqual(KeyLadder.decide(repeated(enter()), latched), .swallow)
        XCTAssertEqual(KeyLadder.decide(repeated(esc()), latched), .swallow)
        XCTAssertEqual(KeyLadder.decide(repeated(enter()), Facts(offer: .none, afterRun: false)), .passThrough)
        XCTAssertEqual(KeyLadder.decide(repeated(enter()), Facts(offer: .resumeQueued, afterRestoreCard: true)), .swallow)
    }

    func testS4AFreshLetterClearsTheLatch() {
        XCTAssertFalse(KeyLadder.afterRestoreCard(was: true, press: letter("a"), action: .passThrough))
    }

    // MARK: - 2611.0015 S17: Return on a queued offer is taken and dropped

    func testS17ReturnOnAQueuedOfferIsDroppedFreshOrRepeated() {
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(offer: .resumeQueued)), .swallow)
        XCTAssertEqual(KeyLadder.decide(repeated(enter()), Facts(offer: .resumeQueued)), .swallow)
        XCTAssertEqual(KeyLadder.decide(letter("a"), Facts(offer: .resumeQueued)), .passThrough)
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(offer: .resumeIdle)), .passThrough)
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(offer: .resumeArmed)), .runResume)
    }

    // MARK: - 2611.0015 S18: with no resume line, any key closes

    func testS18WithNoChoicesReturnAndEscOnlyClose() {
        let noChoices = Facts(restoreCard: [])
        for key in [enter(), esc(), letter("a"), letter("k", command)] {
            XCTAssertEqual(KeyLadder.decide(key, noChoices), .restoreCard(.perCard), "\(key)")
        }
        XCTAssertEqual(KeyLadder.decide(letter("q", command), noChoices), .passThrough)
        XCTAssertEqual(KeyLadder.decide(repeated(enter()), noChoices), .swallow)
        XCTAssertEqual(KeyLadder.decide(enter(), Facts(offer: .resumeArmed, restoreCard: [])), .restoreCard(.perCard))
    }
}
