import AppKit

/// A view that says which cursor the pointer shows over it.
@MainActor
protocol HoverCursorProviding: NSView {
    func hoverCursor(at windowPoint: NSPoint) -> NSCursor
    /// True when a view underneath would answer the same pointer move with a
    /// cursor of its own, so the move must not reach it.
    var claimsPointerMoves: Bool { get }
}

extension HoverCursorProviding {
    var claimsPointerMoves: Bool { false }
}

/// Sets the cursor over the board's chrome: card headers, header buttons, the
/// resize handles and the zoom control.
///
/// Cursor rects cannot do this. The terminal view sets the I-beam on every
/// pointer move inside it, whatever is stacked above it, so a resize handle
/// over a terminal body would flip back to the I-beam on the next move. The
/// router sees each pointer move before it is dispatched, sets the cursor of
/// the view the move would land on, and keeps a move over a resize handle from
/// reaching the content beneath.
@MainActor
final class HoverCursorRouter {
    private var monitor: Any?
    private weak var window: NSWindow?
    /// The last move was over a view that provides its cursor.
    private var showing = false

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

    /// Hands the cursor back once the pointer has left the views that provide one.
    func release() {
        guard showing else { return }
        showing = false
        NSCursor.arrow.set()
    }

    /// Returns whether the move is claimed and must go no further.
    private func route(_ event: NSEvent) -> Bool {
        guard let window, event.window === window,
              let provider = window.contentView?.hitTest(event.locationInWindow) as? HoverCursorProviding
        else {
            release()
            return false
        }
        provider.hoverCursor(at: event.locationInWindow).set()
        showing = true
        return provider.claimsPointerMoves
    }
}
