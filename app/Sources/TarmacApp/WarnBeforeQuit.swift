import AppKit
import TarmacKit

/// The *Warn Before Quitting* toggle: whether ⌘Q is guarded. One value, read by
/// the guard on every Quit, flipped by its menu item, and kept in
/// `app-prefs.json` (`AppPrefsStore`).
@MainActor
final class WarnBeforeQuit: NSObject {
    /// Chromium's wording. The shortcut in it is literal, as in the Tauri app.
    static let title = "Warn Before Quitting (⌘Q)"

    private let prefs: AppPrefsStore

    var enabled: Bool { prefs.values.warnBeforeQuit }

    init(prefs: AppPrefsStore) {
        self.prefs = prefs
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: Self.title, action: #selector(toggle(_:)), keyEquivalent: "")
        item.target = self
        item.state = enabled ? .on : .off
        return item
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        prefs.update { $0.warnBeforeQuit.toggle() }
        sender.state = enabled ? .on : .off
    }
}
