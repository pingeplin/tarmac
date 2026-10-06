import AppKit
import TarmacKit

/// The chosen theme (spec 2610.0007): what is saved, and the variant in
/// effect, which is what every view draws from. `auto` is the variant that
/// fits the macOS appearance, and follows it.
@MainActor
final class ThemeSettings {
    private let prefs: AppPrefsStore
    private var appearanceWatch: NSKeyValueObservation?
    /// The variant in effect changed: views that hold a colour take it again.
    var onChange: (() -> Void)?

    init(prefs: AppPrefsStore) {
        self.prefs = prefs
        apply()
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.resolve() }
        }
    }

    var choice: ThemeChoice { prefs.values.theme }

    var inEffect: ThemeVariant { Theme.variant }

    func choose(_ choice: ThemeChoice) {
        guard choice != self.choice else { return }
        prefs.update { $0.theme = choice }
        apply()
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
    /// variant only while the choice is `auto`, and saves nothing.
    private func resolve() {
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, Self.dark]) == Self.dark
        let variant = choice.inEffect(systemIsDark: systemIsDark)
        guard variant != Theme.variant else { return }
        Theme.variant = variant
        onChange?()
    }
}
