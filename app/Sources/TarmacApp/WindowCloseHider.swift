import AppKit
import TarmacKit

/// Makes the red button — and File ▸ Close Window — hide the window instead of
/// closing it, and brings it back on the next activation or Dock click (spec
/// 2609.0016). `HiddenByClose` hands that comeback out once per close, since
/// one Dock click on an inactive app raises both triggers.
///
/// The ⌘Q guard hides the window too, but with `orderOut`, which never passes
/// through here: a window on its way to quitting is owed no comeback.
@MainActor
final class WindowCloseHider: NSObject, NSWindowDelegate {
    private let hidden = HiddenByClose()
    private weak var window: NSWindow?

    func attach(to window: NSWindow) {
        self.window = window
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        hidden.closeRequested()
        return false
    }

    func restore() {
        guard hidden.takeRestore() else { return }
        window?.makeKeyAndOrderFront(nil)
    }
}
