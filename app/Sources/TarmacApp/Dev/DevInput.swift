#if DEBUG
import AppKit
import QuartzCore
import TarmacKit

/// The input half of the QA driver: builds the `NSEvent`s a verb names and
/// delivers them. What a verb presses, where, and by which delivery is decided
/// in `TarmacKit` (`DevPointer`); this only carries it out.
@MainActor
struct DevInput {
    let window: NSWindow
    /// The app's own handling of a left press that lands on a view — the entry
    /// point its press monitor calls with the view under the pointer.
    let pressHandling: (NSView) -> Void

    // MARK: - Key window

    private var holdsKeys: Bool { NSApp.isActive && window.isKeyWindow }

    /// Makes the window key, activating the app if it has to, and says whether
    /// it had to. Key events go to the key window and the app's press handling
    /// ignores any other, so no key or pointer press lands without it. A locked
    /// screen refuses every activation.
    func takeKey() async throws -> Bool {
        if holdsKeys { return false }
        NSApp.activate(ignoringOtherApps: true)
        // Another of the app's windows — Settings — may hold the keys, and
        // activation alone leaves them there.
        window.makeKeyAndOrderFront(nil)
        let deadline = Uptime.nowMs + UInt64(DevPress.keyWaitMs)
        while !holdsKeys {
            guard Uptime.nowMs < deadline else { throw DevPress.notKey }
            try? await Task.sleep(for: .milliseconds(DevPress.keyPollMs))
        }
        return true
    }

    // MARK: - Pointer

    /// The points a press on `target` may land at, in its own coordinates, with
    /// whether a press there is hit-tested to a view `accepts` takes.
    func candidates(
        on target: NSView, where accepts: (NSView) -> Bool, onLink: (NSPoint) -> Bool = { _ in false }
    ) -> [DevPointer.Candidate] {
        DevTargetPoints.candidates(in: target.bounds).map { point in
            DevPointer.Candidate(
                point: point,
                reachable: hitView(at: target.convert(point, to: nil)).map(accepts) ?? false,
                onLink: onLink(point)
            )
        }
    }

    func hitView(at windowPoint: NSPoint) -> NSView? {
        guard let content = window.contentView else { return nil }
        return content.hitTest(content.superview?.convert(windowPoint, from: nil) ?? windowPoint)
    }

    /// `count` clicks at `point`, given in `target`'s coordinates.
    func click(at point: NSPoint, on target: NSView, by delivery: DevPointer.Delivery, count: Int = 1) throws {
        let location = target.convert(point, to: nil)
        for clicks in 1...count {
            let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map {
                try mouse($0, at: location, clickCount: clicks)
            }
            deliver(events, to: target, by: delivery)
        }
    }

    /// One gesture: a press, any drags, the release.
    ///
    /// `.window` is the path a real event takes once it is off the queue: local
    /// event monitors, the window's hit test and first-responder handling, then
    /// the view.
    ///
    /// `.target` and `.handling` go around `NSApplication.sendEvent`, so of
    /// what a real press runs they keep only what is restated here: the app's
    /// press handling for the target, first responder for a target that
    /// accepts it — what a window does for the view a press lands on — and,
    /// for `.target`, the target's own mouse handlers. No other event monitor
    /// sees the press, and the window does not track it.
    func deliver(_ events: [NSEvent], to target: NSView, by delivery: DevPointer.Delivery) {
        for event in events {
            switch (delivery, event.type) {
            case (.window, _):
                NSApp.sendEvent(event)
            case (_, .leftMouseDown):
                pressHandling(target)
                if target.acceptsFirstResponder { window.makeFirstResponder(target) }
                if delivery == .target { target.mouseDown(with: event) }
            case (.target, .leftMouseDragged):
                target.mouseDragged(with: event)
            case (.target, _):
                target.mouseUp(with: event)
            case (.handling, _):
                break
            }
        }
    }

    func mouse(_ type: NSEvent.EventType, at windowPoint: NSPoint, clickCount: Int = 1) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        ) else { throw DevError(.driverThrew, "could not build a mouse event") }
        return event
    }

    // MARK: - Keys

    /// A key-down and its key-up, through the application's event path: the
    /// app's key monitor first, then the key window's first responder.
    func press(_ stroke: DevKeyStroke) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = stroke.isKeyEquivalentCandidate ? controlKey(type, stroke) : key(type, stroke)
            guard let event else { throw DevError(.driverThrew, "could not build a key event") }
            NSApp.sendEvent(event)
        }
    }

    private func key(_ type: NSEvent.EventType, _ stroke: DevKeyStroke) -> NSEvent? {
        NSEvent.keyEvent(
            with: type, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: stroke.modifierFlags.rawValue),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: stroke.characters, charactersIgnoringModifiers: stroke.charactersIgnoringModifiers,
            isARepeat: false, keyCode: stroke.keyCode
        )
    }

    /// A press with Control, built as a `CGEvent`. The menu takes an
    /// `NSEvent.keyEvent` ⌃C for the system's 🌐⌃C tiling item once the Window
    /// menu has one, and the press never reaches the first responder (#207); it
    /// does not take a `CGEvent` ⌃C, nor a typed one. The price: the event
    /// names no window, so the app's key monitor passes it by, and it has one
    /// string, so `charactersIgnoringModifiers` reads as `characters`.
    private func controlKey(_ type: NSEvent.EventType, _ stroke: DevKeyStroke) -> NSEvent? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: stroke.keyCode, keyDown: type == .keyDown)
        else { return nil }
        event.flags = CGEventFlags(rawValue: UInt64(stroke.modifierFlags.rawValue))
        let characters = Array(stroke.characters.utf16)
        event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        return NSEvent(cgEvent: event)
    }

    // MARK: - Settle

    /// Waits for the UI to catch up with what was just injected (`DevSettle`).
    func settle() async {
        let frames = FrameCounter()
        let link = window.contentView?.displayLink(target: frames, selector: #selector(FrameCounter.tick(_:)))
        // Common modes, so a tracked menu or a live resize cannot stall it.
        link?.add(to: .main, forMode: .common)
        defer { link?.invalidate() }
        let started = Uptime.nowMs
        while !DevSettle.isSettled(framesSeen: frames.count, elapsedMs: Int(Uptime.nowMs - started)) {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
private final class FrameCounter: NSObject {
    private(set) var count = 0

    @objc func tick(_ link: CADisplayLink) {
        count += 1
    }
}
#endif
