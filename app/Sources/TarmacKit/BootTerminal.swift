import Foundation

/// Mints fresh, globally-unique `term_id`s for boot / ⌘T / restored-extra
/// terminals. Isolated in TarmacKit so terminal-id minting has a single home
/// (`AppController` calls `mint()` instead of scattering `UUID().uuidString`),
/// giving one place to change the scheme later (e.g. for deterministic ids).
public enum BootTerminal {
    /// A fresh globally-unique terminal id.
    public static func mint() -> String {
        UUID().uuidString
    }
}
