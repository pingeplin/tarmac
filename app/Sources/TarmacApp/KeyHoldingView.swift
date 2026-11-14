import AppKit

/// An overlay that holds first responder while it is up: the ⌘K switcher, the
/// restore card and the inbox panel. It answers none of the menu's first-responder commands,
/// so a Paste, Copy or Select All chosen from the menu does nothing instead of
/// reaching the terminal behind it.
@MainActor
class KeyHoldingView: NSView {
    /// Who gets keyboard focus back when the overlay closes.
    weak var keysOwner: NSResponder?

    override var acceptsFirstResponder: Bool { true }

    /// Takes first responder, remembering who had it.
    func takeKeys() {
        keysOwner = window?.firstResponder
        window?.makeFirstResponder(self)
    }

    /// Hands first responder back to `keysOwner`, or to `fallback` when that
    /// view has left the window meanwhile.
    func returnKeys(fallback: NSView) {
        defer { keysOwner = nil }
        guard let window, window.firstResponder === self else { return }
        if let owner = keysOwner as? NSView, owner.window === window {
            window.makeFirstResponder(owner)
        } else {
            window.makeFirstResponder(fallback)
        }
    }

    /// A ⌘ chord the menu did not take comes back as a key-down; unanswered,
    /// it would run off the responder chain and the window would beep.
    override func keyDown(with event: NSEvent) {}
}
