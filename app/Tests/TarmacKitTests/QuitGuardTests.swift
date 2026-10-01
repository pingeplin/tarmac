import AppKit
import XCTest
@testable import TarmacKit

/// 2609.0016: every decision the ⌘Q guard makes. Ported from the Rust
/// `quit_guard.rs` tests; S-numbers are the spec's.
final class QuitGuardTests: XCTestCase {
    private let shift = QuitShortcut.shift
    private let control = QuitShortcut.control
    private let option = QuitShortcut.option
    private let command = QuitShortcut.command

    /// A keyboard ⌘Q against the default Quit item, fresh.
    private func cmdQ(
        isKeyDown: Bool = true,
        modifiers: UInt64 = QuitShortcut.command,
        itemMask: UInt64 = QuitShortcut.command,
        keyEquivalent: String = "q",
        ageMs: Int64 = 0
    ) -> QuitGuard.Event {
        QuitGuard.Event(
            isKeyDown: isKeyDown,
            modifiers: modifiers,
            itemMask: itemMask,
            itemKeyEquivalent: keyEquivalent,
            ageMs: ageMs
        )
    }

    /// A guard showing the notice from a tap at `press`.
    private func showing(_ press: UInt64) -> QuitGuard {
        var guardian = QuitGuard()
        _ = guardian.onQuitKey(pressMs: press, keyCode: 12, isRepeat: false)
        return guardian
    }

    /// A guard back in `.idle` after a completed tap: pressed at `press`,
    /// released by the poll at `release`.
    private func tapped(_ press: UInt64, _ release: UInt64) -> QuitGuard {
        var guardian = showing(press)
        _ = guardian.onPoll(sampledMs: release, keyDown: false)
        return guardian
    }

    // MARK: - Routing

    /// S4 (2609.0018) — the snapshot's names for each phase and route.
    func testPhaseAndRouteNamesAreTheSnapshotsWords() {
        XCTAssertEqual(QuitGuard.Phase.idle(lastStartMs: nil).name, "idle")
        XCTAssertEqual(QuitGuard.Phase.idle(lastStartMs: 1).name, "idle")
        XCTAssertEqual(QuitGuard.Phase.showing(startedMs: 1).name, "showing")
        XCTAssertEqual(QuitGuard.Phase.confirming.name, "confirming")
        XCTAssertEqual(QuitGuard.Route.guarded.name, "guard")
        XCTAssertEqual(QuitGuard.Route.terminateNow.name, "terminate")
    }

    /// S1 — the keypress the whole feature exists for.
    func testAFreshKeyboardQuitIsGuarded() {
        XCTAssertEqual(QuitGuard().route(cmdQ(), enabled: true), .guarded)
    }

    /// S2 — a menu click carries a mouse event, and a gesture in progress must
    /// not turn one into a guarded quit either.
    func testANonKeyEventTerminatesEvenMidGesture() {
        let click = cmdQ(isKeyDown: false)
        var guardian = QuitGuard()
        XCTAssertEqual(guardian.route(click, enabled: true), .terminateNow)

        _ = guardian.onQuitKey(pressMs: 10_000, keyCode: 12, isRepeat: false)
        XCTAssertEqual(guardian.route(click, enabled: true), .terminateNow)
        let otherChord = cmdQ(modifiers: option | command)
        XCTAssertEqual(guardian.route(otherChord, enabled: true), .terminateNow)
    }

    /// S3 — keyboard menu navigation ends in a bare Return, and a chord the item
    /// does not carry is somebody else's shortcut.
    func testAKeyDownWhoseModifiersDifferFromTheItemTerminates() {
        let guardian = QuitGuard()
        XCTAssertEqual(guardian.route(cmdQ(modifiers: 0), enabled: true), .terminateNow)
        XCTAssertEqual(guardian.route(cmdQ(modifiers: option | command), enabled: true), .terminateNow)
    }

    /// S4 — Caps Lock, Fn, NumericPad and Help are not part of a shortcut.
    func testModifierBitsOutsideTheShortcutNeverBreakAMatch() {
        let guardian = QuitGuard()
        for extra: UInt64 in [1 << 16, 1 << 23, 1 << 21, 1 << 22] {
            XCTAssertEqual(
                guardian.route(cmdQ(modifiers: command | extra), enabled: true),
                .guarded,
                "extra bit \(String(extra, radix: 16))"
            )
        }
    }

    /// S5 — a remap can store Shift in the key equivalent's character, in the
    /// mask, or in both.
    func testAnUppercaseKeyEquivalentImpliesShift() {
        let guardian = QuitGuard()
        XCTAssertEqual(
            guardian.route(cmdQ(modifiers: shift | command, keyEquivalent: "Q"), enabled: true),
            .guarded
        )
        XCTAssertEqual(guardian.route(cmdQ(keyEquivalent: "Q"), enabled: true), .terminateNow)
        let both = cmdQ(modifiers: shift | command, itemMask: shift | command, keyEquivalent: "Q")
        XCTAssertEqual(guardian.route(both, enabled: true), .guarded)
    }

    /// S6 — the item's live mask is the shortcut, so a user remap is guarded and
    /// the stock chord is not.
    func testARemappedItemGuardsItsOwnChordOnly() {
        let guardian = QuitGuard()
        XCTAssertEqual(
            guardian.route(cmdQ(modifiers: option | command, itemMask: option | command), enabled: true),
            .guarded
        )
        XCTAssertEqual(guardian.route(cmdQ(itemMask: option | command), enabled: true), .terminateNow)
    }

    /// S7 — `currentEvent` is only trusted while it is fresh. A failed check
    /// costs an unguarded quit, never a stuck one. The bound is a literal, not
    /// `freshnessBoundMs ± 1`: an expectation recomputed from the constant would
    /// survive any change to it.
    func testAStaleOrImpossibleTimestampTerminates() {
        let guardian = QuitGuard()
        let cases: [(age: Int64, want: QuitGuard.Route)] = [
            (2_000, .guarded),
            (2_001, .terminateNow),
            (-1, .terminateNow),
            (28_000_000, .terminateNow),
        ]
        for (age, want) in cases {
            XCTAssertEqual(guardian.route(cmdQ(ageMs: age), enabled: true), want, "age \(age)")
        }
    }

    /// S8 — the toggle only decides whether a gesture STARTS. One already running
    /// stays guarded, or a mid-gesture flip would quit on the spot.
    func testTheToggleOffTerminatesOnlyFromIdle() {
        var guardian = QuitGuard()
        XCTAssertEqual(guardian.route(cmdQ(), enabled: false), .terminateNow)

        _ = guardian.onQuitKey(pressMs: 10_000, keyCode: 12, isRepeat: false)
        XCTAssertEqual(guardian.route(cmdQ(), enabled: false), .guarded)
        _ = guardian.onPoll(sampledMs: 10_500, keyDown: true)
        XCTAssertEqual(guardian.route(cmdQ(), enabled: false), .guarded)
    }

    /// S23 — an item with no shortcut cannot have been triggered by a key, so
    /// whatever `currentEvent` holds is somebody else's.
    func testAnItemWithoutAKeyEquivalentIsNeverAKeyboardQuit() {
        XCTAssertEqual(QuitGuard().route(cmdQ(keyEquivalent: ""), enabled: true), .terminateNow)
    }

    /// The item's own mask is masked too: a stray bit in it must not become part
    /// of the chord the handler demands.
    func testABitOutsideTheShortcutInTheItemsMaskIsIgnored() {
        XCTAssertEqual(
            QuitGuard().route(cmdQ(itemMask: command | (1 << 16)), enabled: true),
            .guarded
        )
    }

    /// Only a single-character key equivalent can carry Shift in its character.
    /// A function-key equivalent must not have ⇧ invented for it.
    func testAMultiCharacterKeyEquivalentNeverImpliesShift() {
        XCTAssertEqual(QuitGuard().route(cmdQ(keyEquivalent: "UpArrow"), enabled: true), .guarded)
    }

    // MARK: - Shortcut

    /// S22 — the notice names the shortcut AppKit actually matched.
    func testTheShortcutLabelReadsInApplesOrder() {
        XCTAssertEqual(QuitShortcut.label(keyEquivalent: "q", mask: command), "⌘Q")
        XCTAssertEqual(QuitShortcut.label(keyEquivalent: "q", mask: option | command), "⌥⌘Q")
        XCTAssertEqual(QuitShortcut.label(keyEquivalent: "Q", mask: command), "⇧⌘Q")
        XCTAssertEqual(QuitShortcut.label(keyEquivalent: "Q", mask: shift | command), "⇧⌘Q")
        XCTAssertEqual(
            QuitShortcut.label(keyEquivalent: "q", mask: control | option | shift | command),
            "⌃⌥⇧⌘Q"
        )
        XCTAssertEqual(QuitShortcut.label(keyEquivalent: ".", mask: command), "⌘.")
    }

    /// S22 — and the sentence around it.
    func testTheNoticeNamesTheLiveShortcut() {
        XCTAssertEqual(QuitShortcut.noticeText(keyEquivalent: "q", mask: command), "Hold ⌘Q to Quit")
        XCTAssertEqual(QuitShortcut.noticeText(keyEquivalent: "q", mask: option | command), "Hold ⌥⌘Q to Quit")
    }

    /// `dev_press` refuses a chord by asking what the guard itself expects of a
    /// press on an item, so that rule is public.
    func testExpectedModifiersAreTheItemsMaskPlusAnImpliedShift() {
        XCTAssertEqual(QuitShortcut.expectedModifiers(keyEquivalent: "q", mask: command), command)
        XCTAssertEqual(QuitShortcut.expectedModifiers(keyEquivalent: "Q", mask: command), shift | command)
        XCTAssertEqual(QuitShortcut.expectedModifiers(keyEquivalent: "q", mask: shift | command), shift | command)
        XCTAssertEqual(QuitShortcut.expectedModifiers(keyEquivalent: "q", mask: command | (1 << 16)), command)
        XCTAssertEqual(QuitShortcut.expectedModifiers(keyEquivalent: "UpArrow", mask: command), command)
        XCTAssertEqual(QuitShortcut.expectedModifiers(keyEquivalent: "É", mask: command), shift | command)
        XCTAssertEqual(QuitShortcut.expectedModifiers(keyEquivalent: "ß", mask: command), command)
        XCTAssertEqual(QuitShortcut.expectedModifiers(keyEquivalent: "", mask: command), command)
    }

    /// The kit restates the bits so it needs no AppKit; this is the one place
    /// that checks them against AppKit's own.
    func testTheModifierBitsAreNSEventModifierFlags() {
        XCTAssertEqual(UInt64(NSEvent.ModifierFlags.shift.rawValue), QuitShortcut.shift)
        XCTAssertEqual(UInt64(NSEvent.ModifierFlags.control.rawValue), QuitShortcut.control)
        XCTAssertEqual(UInt64(NSEvent.ModifierFlags.option.rawValue), QuitShortcut.option)
        XCTAssertEqual(UInt64(NSEvent.ModifierFlags.command.rawValue), QuitShortcut.command)
        let ignored: [NSEvent.ModifierFlags] = [.capsLock, .numericPad, .help, .function]
        for flag in ignored {
            XCTAssertEqual(UInt64(flag.rawValue) & QuitShortcut.matched, 0, "\(flag)")
        }
    }

    // MARK: - Gesture

    /// S10 — the notice goes up and the poller follows the key that was pressed,
    /// never a hard-coded Q.
    func testAFirstTapShowsTheNoticeAndPollsThePressedKey() {
        var guardian = QuitGuard()
        XCTAssertEqual(
            guardian.onQuitKey(pressMs: 10_000, keyCode: 12, isRepeat: false),
            [.showHud, .startPolling(keyCode: 12)]
        )
        XCTAssertEqual(guardian.phase, .showing(startedMs: 10_000))

        var remapped = QuitGuard()
        XCTAssertEqual(
            remapped.onQuitKey(pressMs: 10_000, keyCode: 13, isRepeat: false),
            [.showHud, .startPolling(keyCode: 13)]
        )
        XCTAssertEqual(remapped.phase, .showing(startedMs: 10_000))
    }

    /// S11 — released before the threshold: the notice lingers, nothing quits.
    func testAReleaseBeforeTheHoldThresholdIsATap() {
        var guardian = showing(10_000)
        XCTAssertEqual(guardian.onPoll(sampledMs: 10_499, keyDown: true), [])
        XCTAssertEqual(guardian.phase, .showing(startedMs: 10_000))

        XCTAssertEqual(
            guardian.onPoll(sampledMs: 10_120, keyDown: false),
            [.lingerThenFadeHud, .stopPolling]
        )
        XCTAssertEqual(guardian.phase, .idle(lastStartMs: 10_000))
    }

    /// S12 — past the threshold the windows go, and the app exits only once Q is
    /// up: quitting mid-hold would send the repeats to the next app.
    func testAHoldHidesTheWindowsAndExitsOnRelease() {
        var guardian = showing(10_000)
        XCTAssertEqual(guardian.onPoll(sampledMs: 10_500, keyDown: true), [.hideWindows])
        XCTAssertEqual(guardian.phase, .confirming)

        XCTAssertEqual(guardian.onPoll(sampledMs: 10_550, keyDown: true), [])
        XCTAssertEqual(guardian.phase, .confirming)

        XCTAssertEqual(guardian.onPoll(sampledMs: 10_600, keyDown: false), [.stopPolling, .exit])
        XCTAssertEqual(guardian.phase, .idle(lastStartMs: nil))
    }

    /// S13 — the first sample can arrive late (WebKit's round trip, or a stalled
    /// poller). What it reads is what happened, not how long it took.
    func testTheFirstPollDecidesOnWhatItReadsHoweverLateItIs() {
        var released = showing(10_000)
        XCTAssertEqual(
            released.onPoll(sampledMs: 10_700, keyDown: false),
            [.lingerThenFadeHud, .stopPolling]
        )
        XCTAssertEqual(released.phase, .idle(lastStartMs: 10_000))

        var held = showing(10_000)
        XCTAssertEqual(held.onPoll(sampledMs: 10_700, keyDown: true), [.hideWindows])
        XCTAssertEqual(held.phase, .confirming)
    }

    /// A sample older than the press that started the gesture counts as no time
    /// held (`saturating_sub` in the Rust): the gesture neither advances nor
    /// traps on an underflowing subtraction.
    func testASampleOlderThanThePressHasHeldForNoTime() {
        var guardian = showing(10_000)
        XCTAssertEqual(guardian.onPoll(sampledMs: 9_999, keyDown: true), [])
        XCTAssertEqual(guardian.phase, .showing(startedMs: 10_000))
        XCTAssertEqual(guardian.onPoll(sampledMs: 0, keyDown: true), [])
        XCTAssertEqual(guardian.phase, .showing(startedMs: 10_000))
        XCTAssertEqual(guardian.onPoll(sampledMs: 10_500, keyDown: true), [.hideWindows])
    }

    /// S14 — Chromium's second tap, measured from the first PRESS.
    func testASecondTapWithinTheWindowCommitsTheQuit() {
        var guardian = tapped(0, 400)
        XCTAssertEqual(
            guardian.onQuitKey(pressMs: 950, keyCode: 12, isRepeat: false),
            [.hideWindows, .startPolling(keyCode: 12)]
        )
        XCTAssertEqual(guardian.phase, .confirming)

        XCTAssertEqual(guardian.onPoll(sampledMs: 1_000, keyDown: false), [.stopPolling, .exit])
        XCTAssertEqual(guardian.phase, .idle(lastStartMs: nil))
    }

    /// S15/S21 — the window is a strict 1 s from the previous press, not from its
    /// release.
    func testTheSecondTapWindowClosesOneSecondAfterThePreviousPress() {
        for press: UInt64 in [1_000, 1_050] {
            var guardian = tapped(0, 400)
            XCTAssertEqual(
                guardian.onQuitKey(pressMs: press, keyCode: 12, isRepeat: false),
                [.showHud, .startPolling(keyCode: 12)],
                "press at \(press)"
            )
            XCTAssertEqual(guardian.phase, .showing(startedMs: press))
        }

        var guardian = tapped(0, 400)
        XCTAssertEqual(
            guardian.onQuitKey(pressMs: 999, keyCode: 12, isRepeat: false),
            [.hideWindows, .startPolling(keyCode: 12)]
        )
        XCTAssertEqual(guardian.phase, .confirming)
    }

    /// S21 — a press older than the last start (a clock that went backwards, or
    /// an out-of-order delivery) is simply not recent.
    func testAPressOlderThanTheLastStartIsNotASecondTap() {
        var guardian = tapped(1_000, 1_100)
        XCTAssertEqual(
            guardian.onQuitKey(pressMs: 900, keyCode: 12, isRepeat: false),
            [.showHud, .startPolling(keyCode: 12)]
        )
        XCTAssertEqual(guardian.phase, .showing(startedMs: 900))
    }

    /// S16 — Q was re-pressed before a poll saw the release, so this is a second
    /// tap by another name. The poller is already running on the first chord's
    /// key, and keeps it.
    func testARePressWhileTheNoticeShowsCommitsWithoutASecondPoller() {
        var guardian = showing(10_000)
        XCTAssertEqual(guardian.onQuitKey(pressMs: 10_300, keyCode: 13, isRepeat: false), [.hideWindows])
        XCTAssertEqual(guardian.phase, .confirming)
    }

    /// S17 — once committed, another chord changes nothing.
    func testARePressWhileConfirmingDoesNothing() {
        var guardian = showing(10_000)
        _ = guardian.onPoll(sampledMs: 10_500, keyDown: true)
        XCTAssertEqual(guardian.onQuitKey(pressMs: 10_700, keyCode: 12, isRepeat: false), [])
        XCTAssertEqual(guardian.phase, .confirming)
    }

    /// S18 — auto-repeat reaches the retargeted item too, and must never advance
    /// the gesture.
    func testAutoRepeatsAreIgnoredInEveryPhase() {
        var idle = tapped(10_000, 10_120)
        XCTAssertEqual(idle.onQuitKey(pressMs: 10_200, keyCode: 12, isRepeat: true), [])
        XCTAssertEqual(idle.phase, .idle(lastStartMs: 10_000))

        var notice = showing(10_000)
        XCTAssertEqual(notice.onQuitKey(pressMs: 10_100, keyCode: 12, isRepeat: true), [])
        XCTAssertEqual(notice.phase, .showing(startedMs: 10_000))

        var confirming = showing(10_000)
        _ = confirming.onPoll(sampledMs: 10_500, keyDown: true)
        XCTAssertEqual(confirming.onQuitKey(pressMs: 10_560, keyCode: 12, isRepeat: true), [])
        XCTAssertEqual(confirming.phase, .confirming)
    }

    /// S18 — if key state is unreadable the first sample reads "up", so the hold
    /// ends as a tap and the auto-repeats that follow cannot confirm it. A real
    /// second tap still can.
    func testAHoldWhoseFirstPollReadsUpEndsAsATapThatRepeatsCannotConfirm() {
        var guardian = tapped(0, 50)
        // Inside the second-tap window, so `isRepeat` is the only thing standing
        // between this press and `.confirming`.
        XCTAssertEqual(guardian.onQuitKey(pressMs: 500, keyCode: 12, isRepeat: true), [])
        XCTAssertEqual(guardian.phase, .idle(lastStartMs: 0))

        var second = tapped(0, 50)
        XCTAssertEqual(second.onQuitKey(pressMs: 500, keyCode: 12, isRepeat: true), [])
        XCTAssertEqual(
            second.onQuitKey(pressMs: 900, keyCode: 12, isRepeat: false),
            [.hideWindows, .startPolling(keyCode: 12)]
        )
        XCTAssertEqual(second.phase, .confirming)
    }

    /// S20 — WebKit re-sends the original `NSEvent`, so the same press can arrive
    /// twice. Treating the second as a new chord would turn a tap into a quit.
    func testTheSameKeyDownDeliveredTwiceAdvancesNothing() {
        var guardian = showing(10_000)
        XCTAssertEqual(guardian.onQuitKey(pressMs: 10_000, keyCode: 12, isRepeat: false), [])
        XCTAssertEqual(guardian.phase, .showing(startedMs: 10_000))

        var afterTap = tapped(10_000, 10_120)
        XCTAssertEqual(afterTap.onQuitKey(pressMs: 10_000, keyCode: 12, isRepeat: false), [])
        XCTAssertEqual(afterTap.phase, .idle(lastStartMs: 10_000))

        var withRepeat = showing(10_000)
        XCTAssertEqual(withRepeat.onQuitKey(pressMs: 10_100, keyCode: 12, isRepeat: true), [])
        XCTAssertEqual(withRepeat.onQuitKey(pressMs: 10_000, keyCode: 12, isRepeat: false), [])
        XCTAssertEqual(withRepeat.phase, .showing(startedMs: 10_000))
    }

    // MARK: - Clock

    /// S38 — the wiring never subtracts `UInt64`s itself: a future timestamp is a
    /// negative age, and a zero one is ancient.
    func testAnEventsAgeIsSignedAndItsTimestampIsWholeMilliseconds() {
        XCTAssertEqual(QuitGuard.ageMs(nowMs: 1_000, pressMs: 1_001), -1)
        XCTAssertEqual(QuitGuard.ageMs(nowMs: 1_001, pressMs: 1_000), 1)
        XCTAssertEqual(QuitGuard.ageMs(nowMs: 28_000_000, pressMs: QuitGuard.pressMs(timestampSeconds: 0)), 28_000_000)
        XCTAssertEqual(QuitGuard.pressMs(timestampSeconds: 12.3456), 12_345)
        XCTAssertEqual(QuitGuard.pressMs(timestampSeconds: 0), 0)
        XCTAssertEqual(QuitGuard.pressMs(timestampSeconds: -1), 0)
    }

    /// A NaN or infinite `NSEvent.timestamp` must saturate, not trap: the Quit
    /// handler runs inside the key event.
    func testAnUnrepresentableTimestampSaturatesInsteadOfTrapping() {
        XCTAssertEqual(QuitGuard.pressMs(timestampSeconds: .nan), 0)
        XCTAssertEqual(QuitGuard.pressMs(timestampSeconds: -.infinity), 0)
        XCTAssertEqual(QuitGuard.pressMs(timestampSeconds: .infinity), .max)
        XCTAssertEqual(QuitGuard.pressMs(timestampSeconds: 1e30), .max)
    }

    /// A saturated press is the far future: its age is negative, never a wrapped
    /// small positive that would pass the freshness check, and never a trap.
    func testASaturatedPressIsInTheFutureNotFresh() {
        XCTAssertLessThan(QuitGuard.ageMs(nowMs: 1_000, pressMs: .max), 0)
        XCTAssertLessThan(QuitGuard.ageMs(nowMs: 0, pressMs: .max), 0)
        XCTAssertEqual(QuitGuard.ageMs(nowMs: .max, pressMs: 0), Int64.max)
    }

    // MARK: - Constants

    /// Every threshold, as a literal: the tests above exercise them through
    /// values, this pins the numbers the AppKit layer reads.
    func testTheTimingConstants() {
        XCTAssertEqual(QuitGuard.holdMs, 500)
        XCTAssertEqual(QuitGuard.secondTapMs, 1_000)
        XCTAssertEqual(QuitGuard.freshnessBoundMs, 2_000)
        XCTAssertEqual(QuitGuard.pollMs, 50)
        XCTAssertEqual(QuitGuard.lingerMs, 1_000)
        XCTAssertEqual(QuitGuard.fadeMs, 200)
    }

    /// The notice fades in ten alpha steps over `fadeMs`: no Core Animation, so
    /// no completion handler to generation-guard. Ends fully transparent.
    func testTheFadeIsTenStepsOverTwoHundredMilliseconds() {
        XCTAssertEqual(QuitGuard.fadeSteps, 10)
        XCTAssertEqual(QuitGuard.fadeStepMs, 20)
        let alphas = (1...QuitGuard.fadeSteps).map(QuitGuard.fadeAlpha(step:))
        XCTAssertEqual(alphas.count, 10)
        for (alpha, want) in zip(alphas, [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1, 0.0]) {
            XCTAssertEqual(alpha, want, accuracy: 1e-9)
        }
        XCTAssertEqual(alphas.last, 0)
    }
}
