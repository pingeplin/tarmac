import AppKit

/// A view that says which cursor the pointer shows over it.
@MainActor
protocol HoverCursorProviding: NSView {
    func hoverCursor(at windowPoint: NSPoint) -> NSCursor
    /// True when a view underneath would answer the same pointer move with a
    /// cursor of its own, whatever lies above it, so the move must not reach it.
    var claimsPointerMoves: Bool { get }
}

extension HoverCursorProviding {
    var claimsPointerMoves: Bool { false }
}

/// Sets the cursor over the board's chrome: card headers, header buttons, the
/// resize handles, a showing scroll thumb and the zoom control. It also says
/// which view each pointer move lands on (`onMove`), which is how a card
/// learns that the pointer is over its scroll thumb.
///
/// The router sees each pointer move before it is dispatched and sets the
/// cursor of the view the move would land on. A resize handle lies over its
/// card's body, which sets a cursor of its own on a move. A terminal does so
/// only when the move lands on it. A web view is handed every move over it,
/// under a handle or not — WebKit hit-tests first only from bug 312923 on,
/// which the system framework of macOS 26.7 does not have — and the page can
/// answer with its own cursor after the handle's is set. So a move the
/// provider claims stops here.
@MainActor
final class HoverCursorRouter {
    private var monitor: Any?
    private weak var window: NSWindow?
    /// The last move was over a view that provides its cursor.
    private var showing = false
    /// Told the view each pointer move lands on; nil when it lands on none,
    /// and when the pointer leaves.
    var onMove: ((NSView?) -> Void)?

    /// Routes the pointer in `window`, or stops with nil.
    func attach(to window: NSWindow?) {
        self.window = window
        if window == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            showing = false
        } else if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                let claimed = MainActor.assumeIsolated { self?.route(event) ?? false }
                return claimed ? nil : event
            }
        }
    }

    /// The pointer left the board.
    func pointerLeft() {
        onMove?(nil)
        release()
    }

    /// Hands the cursor back once the pointer has left the views that provide one.
    private func release() {
        guard showing else { return }
        showing = false
        NSCursor.arrow.set()
    }

    /// Returns whether the move is claimed and must go no further.
    private func route(_ event: NSEvent) -> Bool {
        let hit = window.flatMap { event.window === $0 ? $0.contentView?.hitTest(event.locationInWindow) : nil }
        onMove?(hit)
        guard let provider = hit as? HoverCursorProviding else {
            release()
            return false
        }
        provider.hoverCursor(at: event.locationInWindow).set()
        showing = true
        return provider.claimsPointerMoves
    }
}
