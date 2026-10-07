import AppKit
import TarmacKit

/// The chosen theme (specs 2610.0007, 2610.0008): what is saved, and the
/// theme in effect, which is what every view draws from. `auto` is the theme
/// chosen for the macOS appearance, and follows it.
///
/// The app's appearance is the variant of the theme in effect, under `auto`
/// too, so each window the app has follows the theme with no code of its
/// own. With an appearance set, the one the app reports as in effect is
/// that one and not the Mac's, so the Mac's is read from the preference the
/// Mac writes.
@MainActor
final class ThemeSettings {
    private static let interfaceStyleKey = "AppleInterfaceStyle"

    private let prefs: AppPrefsStore
    private var systemWatch: DefaultsWatch?
    /// The theme in effect changed: views that hold a colour take it again.
    var onChange: (() -> Void)?

    init(prefs: AppPrefsStore) {
        self.prefs = prefs
        resolve()
        // `resolve` sets it only for a change, and the theme of a fresh
        // launch is the one `Theme` starts with.
        showAppearance()
        systemWatch = DefaultsWatch(key: Self.interfaceStyleKey) { [weak self] in self?.resolve() }
    }

    var choice: ThemeChoice { prefs.values.theme }

    var inEffect: ThemeCatalog.Entry { Theme.entry }

    /// The theme id held for each appearance. With no entry, or with the id
    /// of its standard theme, an appearance has its standard theme.
    var themes: [ThemeVariant: String] { prefs.values.themes }

    /// The theme chosen for an appearance: the saved one, or the standard one.
    func theme(for variant: ThemeVariant) -> ThemeCatalog.Entry {
        ThemeCatalog.entry(prefs.values.themes[variant], for: variant)
    }

    func choose(_ choice: ThemeChoice) {
        guard choice != self.choice else { return }
        prefs.update { $0.theme = choice }
        resolve()
    }

    func choose(_ theme: ThemeCatalog.Entry, for variant: ThemeVariant) {
        guard theme.id != self.theme(for: variant).id else { return }
        prefs.update { $0.themes[variant] = theme.id }
        resolve()
    }

    private func showAppearance() {
        NSApp.appearance = NSAppearance(named: Theme.entry.variant == .dark ? .darkAqua : .aqua)
    }

    /// Also what the watch runs: a change of the Mac's appearance moves the
    /// theme only while the choice is `auto`, and saves nothing.
    private func resolve() {
        let systemIsDark = ThemeChoice.systemIsDark(
            interfaceStyle: UserDefaults.standard.string(forKey: Self.interfaceStyleKey)
        )
        let entry = ThemeCatalog.inEffect(choice: choice, themes: prefs.values.themes, systemIsDark: systemIsDark)
        guard entry.id != Theme.entry.id else { return }
        Theme.entry = entry
        showAppearance()
        onChange?()
    }
}

/// Tells of each change of one key of `UserDefaults.standard`, for as long as
/// it lives. `UserDefaults` has a key path only for a key it declares, so the
/// typed `observe` cannot name `AppleInterfaceStyle`.
private final class DefaultsWatch: NSObject {
    private let key: String
    private let changed: @MainActor () -> Void

    init(key: String, changed: @escaping @MainActor () -> Void) {
        self.key = key
        self.changed = changed
        super.init()
        UserDefaults.standard.addObserver(self, forKeyPath: key, context: nil)
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: key)
    }

    // Nothing says which thread a change of a global preference is told on.
    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor [changed] in changed() }
    }
}
