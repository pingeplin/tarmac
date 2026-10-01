import AppKit
import TarmacKit

/// The AppKit half of the ⌘Q guard (spec 2609.0016): the Quit menu item's
/// target. Every decision is `QuitGuard`'s; this reads the event the item was
/// invoked from and applies the effects that come back.
///
/// The guard sits on the menu item rather than in
/// `applicationShouldTerminate`, so only the Quit *shortcut* is held: Dock ▸
/// Quit, logout and the guard's own exit call `terminate` directly and never
/// come through here. AppKit decides which chord the item answers to, so no
/// character is ever compared and every input source and user remap works.
@MainActor
final class QuitGuardController: NSObject {
    static let quitAction = #selector(quit(_:))

    let warning: WarnBeforeQuit
    private var machine = QuitGuard()
    private let poller = KeyReleasePoller()
    private var notice: QuitNoticePanel?
    /// Bumped whenever the notice is shown or must stay, so a linger or fade
    /// left over from an earlier tap cannot take the current notice away.
    private var noticeGeneration: UInt64 = 0
    private weak var window: NSWindow?

    #if DEBUG
    /// The most recent keyboard press the handler saw; a menu click leaves it.
    private var lastPress: DevSnapshot.QuitGuard.Press?
    #endif

    init(window: NSWindow, warning: WarnBeforeQuit) {
        self.window = window
        self.warning = warning
    }

    @objc func quit(_ sender: Any?) {
        let item = sender as? NSMenuItem
        let event = NSApp.currentEvent
        let isKeyDown = event?.type == .keyDown
        // keyCode and isARepeat are only valid on a key event.
        let key = isKeyDown ? event : nil
        let pressMs = key.map { QuitGuard.pressMs(timestampSeconds: $0.timestamp) } ?? 0
        let quitEvent = QuitGuard.Event(
            isKeyDown: isKeyDown,
            modifiers: UInt64(event?.modifierFlags.rawValue ?? 0),
            itemMask: UInt64(item?.keyEquivalentModifierMask.rawValue ?? 0),
            itemKeyEquivalent: item?.keyEquivalent ?? "",
            ageMs: QuitGuard.ageMs(nowMs: Uptime.nowMs, pressMs: pressMs)
        )
        let route = machine.route(quitEvent, enabled: warning.enabled)
        #if DEBUG
        Self.log(route: route, event: event, quitEvent: quitEvent, pressMs: pressMs)
        if isKeyDown {
            lastPress = DevSnapshot.QuitGuard.Press(
                pressMs: pressMs, route: DevSnapshot.QuitGuard.Route(route), ageMs: quitEvent.ageMs
            )
        }
        #endif

        switch route {
        case .terminateNow:
            NSApp.terminate(nil)
        case .guarded:
            apply(
                machine.onQuitKey(pressMs: pressMs, keyCode: key?.keyCode ?? 0, isRepeat: key?.isARepeat ?? false),
                noticeText: QuitShortcut.noticeText(
                    keyEquivalent: quitEvent.itemKeyEquivalent, mask: quitEvent.itemMask
                )
            )
        }
    }

    private func apply(_ effects: [QuitGuard.Effect], noticeText: String? = nil) {
        for effect in effects {
            switch effect {
            case .showHud:
                if let noticeText { showNotice(noticeText) }
            case .lingerThenFadeHud:
                lingerThenFade()
            case .hideWindows:
                noticeGeneration += 1
                // Not `performClose`: a window the guard hid is on its way out
                // and must not be owed a comeback.
                window?.orderOut(nil)
            case .startPolling(let keyCode):
                poller.start(keyCode: keyCode) { [weak self] held in
                    guard let self else { return }
                    self.apply(self.machine.onPoll(sampledMs: Uptime.nowMs, keyDown: held))
                }
            case .stopPolling:
                poller.stop()
            case .exit:
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Notice

    private func showNotice(_ text: String) {
        noticeGeneration += 1
        let notice = self.notice ?? QuitNoticePanel()
        self.notice = notice
        let onScreen = (window?.isVisible ?? false) && !(window?.isMiniaturized ?? false)
        notice.show(text, on: QuitNotice.pickScreen(
            windowScreen: window?.screen, windowOnScreen: onScreen,
            mainScreen: NSScreen.main, firstScreen: NSScreen.screens.first
        ))
    }

    /// The only thing that takes the notice away. On the hold path it stays up
    /// over the hidden window until the app exits.
    private func lingerThenFade() {
        let generation = noticeGeneration
        for step in QuitNotice.fadeSteps {
            after(step.afterMs, ifStill: generation) { $0.alpha = step.alpha }
        }
        after(QuitNotice.dismissAfterMs, ifStill: generation) { $0.dismiss() }
    }

    /// Runs `change` on the notice unless it has been shown again, or pinned by
    /// a committed quit, since. The main queue is serviced in the common
    /// run-loop modes, so a tracked menu does not stall the fade.
    private func after(
        _ delayMs: UInt64,
        ifStill generation: UInt64,
        _ change: @escaping @MainActor @Sendable (QuitNoticePanel) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noticeGeneration == generation, let notice = self.notice else { return }
                change(notice)
            }
        }
    }
}

#if DEBUG
extension QuitGuardController {
    /// What the QA driver's snapshot reports as `quit_guard` (spec 2609.0018).
    /// `retargeted` is whether the guard still owns every Quit item: anything
    /// that replaces the main menu silently drops that.
    var facts: DevSnapshot.QuitGuard {
        DevSnapshot.QuitGuard(
            retargeted: ownsQuit(in: NSApp.mainMenu),
            enabled: warning.enabled,
            phase: DevSnapshot.QuitGuard.Phase(machine.phase),
            noticeVisible: notice?.isVisible ?? false,
            noticeAlpha: notice?.alpha ?? 0,
            lastPress: lastPress
        )
    }

    /// `tarmac dev press`: `keyCode` reads as held to the release poll until
    /// `untilMs` on the `Uptime` clock, whatever the keyboard says.
    func hold(keyCode: UInt16, untilMs: UInt64) {
        poller.hold = KeyHold(keyCode: keyCode, untilMs: untilMs)
    }

    /// The item holds its target weakly, so an item left on the guard's
    /// selector with the guard gone is disabled by AppKit, not guarded.
    private func ownsQuit(in menu: NSMenu?) -> Bool {
        var guarded = 0
        var native = 0
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.action == Self.quitAction {
                    if item.target != nil { guarded += 1 }
                } else if item.action == #selector(NSApplication.terminate(_:)) {
                    native += 1
                } else if let submenu = item.submenu {
                    walk(submenu)
                }
            }
        }
        if let menu { walk(menu) }
        return QuitNotice.guardOwnsQuit(guardedItems: guarded, nativeItems: native)
    }

    private static func log(route: QuitGuard.Route, event: NSEvent?, quitEvent: QuitGuard.Event, pressMs: UInt64) {
        // `-` for a field this event cannot carry: there is no event at all
        // behind a VoiceOver press.
        func show(_ value: String?) -> String { value ?? "-" }
        let type = event.map { String($0.type.rawValue) }
        let isRepeat = quitEvent.isKeyDown ? event.map { String($0.isARepeat) } : nil
        let line = "tarmac: quit-key route=\(route.name) type=\(show(type)) repeat=\(show(isRepeat))"
            + " age_ms=\(show(event.map { _ in String(quitEvent.ageMs) }))"
            + " press_ms=\(show(event.map { _ in String(pressMs) }))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
#endif
