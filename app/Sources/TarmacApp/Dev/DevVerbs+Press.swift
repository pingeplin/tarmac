#if DEBUG
import AppKit
import TarmacKit

/// `tarmac dev press` (spec 2609.0018, #183; parity row Q19): a native ⌘ chord
/// posted to the application's event queue, so it takes the path a typed one
/// does — the key monitor, then the menu — and the ⌘Q guard reads it off
/// `NSApp.currentEvent` like any other. What may be posted is `DevPress`'s.
extension DevVerbs {
    func press(combo: String, holdMs: Int?, ageMs: Int?, busyMs: Int?) async throws -> JSONValue {
        let plan = try DevPress.plan(combo: combo, holdMs: holdMs, ageMs: ageMs, busyMs: busyMs).get()
        guard !reachesAnUnguardedQuit(plan.chord, in: NSApp.mainMenu) else {
            throw DevPress.notRetargeted(combo: combo)
        }
        let activated = try await input.takeKey()

        let now = Uptime.nowMs
        // No posted event makes the keyboard read a key as down, so the guard's
        // release poll is told how long this one is held.
        quitGuard.hold(keyCode: plan.chord.keyCode, untilMs: now + plan.holdMs)
        let pressMs = DevPress.pressMs(nowMs: now, ageMs: plan.ageMs)
        try post(.keyDown, plan.chord, stampMs: pressMs)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(plan.holdMs))) { [weak self] in
            MainActor.assumeIsolated { try? self?.post(.keyUp, plan.chord, stampMs: Uptime.nowMs) }
        }
        if let busyMs = plan.busyMs { stall(ms: busyMs) }
        return DevPress.reply(combo: combo, pressMs: pressMs, plan: plan, activated: activated)
    }

    /// `--busy` stands for an app too busy to take the key: the main thread is
    /// blocked behind the posted press, which is read only once it is let go.
    private func stall(ms: UInt64) {
        Thread.sleep(forTimeInterval: TimeInterval(ms) / 1_000)
    }

    /// Would this chord reach a native `terminate:` item, or a Quit item whose
    /// guard is gone? Walked the way `QuitGuardController.facts` walks, so the
    /// two agree on what the menu holds.
    private func reachesAnUnguardedQuit(_ chord: DevPress.Chord, in menu: NSMenu?) -> Bool {
        guard let menu else { return false }
        return menu.items.contains { item in
            let native = item.action == #selector(NSApplication.terminate(_:))
            let orphaned = item.action == QuitGuardController.quitAction && item.target == nil
            guard native || orphaned else { return reachesAnUnguardedQuit(chord, in: item.submenu) }
            return DevPress.matchesItem(
                chord, keyEquivalent: item.keyEquivalent, mask: UInt64(item.keyEquivalentModifierMask.rawValue)
            )
        }
    }

    private func post(_ type: NSEvent.EventType, _ chord: DevPress.Chord, stampMs: UInt64) throws {
        guard let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(chord.flags)),
            timestamp: TimeInterval(stampMs) / 1_000, windowNumber: window.windowNumber, context: nil,
            characters: chord.characters, charactersIgnoringModifiers: chord.characters,
            isARepeat: false, keyCode: chord.keyCode
        ) else { throw DevError(.driverThrew, "could not build a key event") }
        NSApp.postEvent(event, atStart: false)
    }
}
#endif
