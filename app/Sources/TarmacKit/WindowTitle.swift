import Foundation

/// The window title, which is also what the Dock, Exposé and the window list
/// show for the app. Ports `desktop/src/kit/devTitle.ts` and the title effect in
/// `desktop/src/App.tsx`.
///
/// Known difference: JavaScript's `trim()` also strips U+FEFF and leaves
/// U+0085, the reverse of `.whitespacesAndNewlines`.
public enum WindowTitle {
    /// Names a dev app by its worktree, so several running side by side can be
    /// told apart; empty for a shipped app, which has no label.
    public static func devSuffix(label: String?) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "" : " · \(trimmed)"
    }

    /// The glyph and the padding spaces are literal.
    public static func text(boardName: String?, boardID: String, devLabel: String?) -> String {
        let trimmed = boardName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = !trimmed.isEmpty ? trimmed : !boardID.isEmpty ? boardID : "tarmac"
        return " ▞ \(name)\(devSuffix(label: devLabel)) "
    }
}
