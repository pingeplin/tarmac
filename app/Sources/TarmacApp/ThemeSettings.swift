import AppKit
import TarmacKit

/// The chosen theme (specs 2610.0007, 2610.0008): what is saved, and the
/// theme in effect, which is what every view draws from. `auto` is the theme
/// chosen for the macOS appearance, and follows it.
@MainActor
final class ThemeSettings {
    private let prefs: AppPrefsStore
    private var appearanceWatch: NSKeyValueObservation?
    /// The theme in effect changed: views that hold a colour take it again.
    var onChange: (() -> Void)?

    init(prefs: AppPrefsStore) {
        self.prefs = prefs
        apply()
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.resolve() }
        }
    }

    var choice: ThemeChoice { prefs.values.theme }

    var inEffect: ThemeCatalog.Entry { Theme.entry }

    /// The theme chosen for an appearance: the saved one, or the standard one.
    func theme(for variant: ThemeVariant) -> ThemeCatalog.Entry {
        ThemeCatalog.entry(prefs.values.themes[variant], for: variant)
    }

    func choose(_ choice: ThemeChoice) {
        guard choice != self.choice else { return }
        prefs.update { $0.theme = choice }
        apply()
    }

    func choose(_ theme: ThemeCatalog.Entry, for variant: ThemeVariant) {
        guard theme.id != self.theme(for: variant).id else { return }
        prefs.update { $0.themes[variant] = theme.id }
        resolve()
    }

    private static let dark = NSAppearance.Name.darkAqua

    /// No appearance of the app's own for `auto`: with one set,
    /// `effectiveAppearance` reports it and not the Mac's.
    private var appearance: NSAppearance? {
        switch choice {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: Self.dark)
        }
    }

    private func apply() {
        NSApp.appearance = appearance
        resolve()
    }

    /// Also what the watch runs: a change of the Mac's appearance moves the
    /// theme only while the choice is `auto`, and saves nothing.
    private func resolve() {
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, Self.dark]) == Self.dark
        let entry = ThemeCatalog.inEffect(choice: choice, themes: prefs.values.themes, systemIsDark: systemIsDark)
        guard entry.id != Theme.entry.id else { return }
        Theme.entry = entry
        onChange?()
    }
}
