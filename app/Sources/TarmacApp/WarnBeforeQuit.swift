import AppKit
import TarmacKit

/// The *Warn Before Quitting* toggle: whether ⌘Q is guarded. One value, read by
/// the guard on every Quit, flipped by its menu item, and kept in
/// `app-prefs.json` beside the daemon socket — the one location that already
/// separates a dev app from the installed one, which share a bundle id.
@MainActor
final class WarnBeforeQuit: NSObject {
    /// Chromium's wording. The shortcut in it is literal, as in the Tauri app.
    static let title = "Warn Before Quitting (⌘Q)"

    private(set) var enabled: Bool
    private let prefsPath: String

    init(prefsPath: String) {
        self.prefsPath = prefsPath
        enabled = AppPrefs.load(from: prefsPath)
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: Self.title, action: #selector(toggle(_:)), keyEquivalent: "")
        item.target = self
        item.state = enabled ? .on : .off
        return item
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.state = enabled ? .on : .off
        do {
            try AppPrefs.save(warnBeforeQuit: enabled, to: prefsPath)
        } catch {
            // This session obeys the toggle either way; only the next launch
            // misses it.
            FileHandle.standardError.write(Data("tarmac: could not save app prefs: \(error)\n".utf8))
        }
    }
}
