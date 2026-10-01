#if DEBUG
import AppKit
import QuartzCore
import TarmacKit

/// The input half of the QA driver: builds the `NSEvent`s a verb names and
/// sends them through `NSApplication.sendEvent`, the path a real event takes
/// once it is off the queue — local event monitors, the window's hit test and
/// first-responder handling, then the view. What a verb presses, and where, is
/// decided in `TarmacKit`.
@MainActor
struct DevInput {
    let window: NSWindow

    // MARK: - Key window

    private var holdsKeys: Bool { NSApp.isActive && window.isKeyWindow }

    /// Makes the window key, activating the app if it has to, and says whether
    /// it had to. Key events go to the key window and the board's press
    /// handling ignores any other, so nothing a verb injects lands without it.
    /// A locked screen refuses every activation.
    func takeKey() async throws -> Bool {
        if holdsKeys { return false }
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Uptime.nowMs + UInt64(DevPress.keyWaitMs)
        while !holdsKeys {
            guard Uptime.nowMs < deadline else { throw DevPress.notKey }
            try? await Task.sleep(for: .milliseconds(DevPress.keyPollMs))
        }
        return true
    }

    // MARK: - Pointer

    /// A point on `target`, in window coordinates, where a press is hit-tested
    /// to a view `accepts` takes — nil when every candidate is off screen or
    /// under something else.
    func point(on target: NSView, where accepts: (NSView) -> Bool) -> NSPoint? {
        DevTargetPoints.candidates(in: target.bounds)
            .map { target.convert($0, to: nil) }
            .first { hitView(at: $0).map(accepts) ?? false }
    }

    func hitView(at windowPoint: NSPoint) -> NSView? {
        guard let content = window.contentView else { return nil }
        return content.hitTest(content.superview?.convert(windowPoint, from: nil) ?? windowPoint)
    }

    func click(at windowPoint: NSPoint, count: Int = 1) throws {
        for clicks in 1...count {
            send(try mouse(.leftMouseDown, at: windowPoint, clickCount: clicks))
            send(try mouse(.leftMouseUp, at: windowPoint, clickCount: clicks))
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

    func press(_ stroke: DevKeyStroke) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: stroke.modifierFlags.rawValue),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: stroke.characters, charactersIgnoringModifiers: stroke.charactersIgnoringModifiers,
                isARepeat: false, keyCode: stroke.keyCode
            ) else { throw DevError(.driverThrew, "could not build a key event") }
            send(event)
        }
    }

    func send(_ event: NSEvent) {
        NSApp.sendEvent(event)
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
