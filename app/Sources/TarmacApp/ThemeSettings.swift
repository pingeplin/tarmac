import AppKit
import TarmacKit

/// The chosen theme (specs 2610.0007, 2610.0008, 2610.0009): what is saved,
/// the themes there are, and the theme in effect, which is what every view
/// draws from. `auto` is the theme chosen for the macOS appearance, and
/// follows it. The themes are the built-in ones and those of the files in
/// the user's folder, which is read again at each change in it.
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
    /// Where the user's theme files are.
    let folder: String
    private var systemWatch: DefaultsWatch?
    private var folderWatch: ThemeFolderWatch?
    private(set) var library: ThemeLibrary
    /// The theme in effect changed: views that hold a colour take it again.
    var onChange: (() -> Void)?
    /// The themes changed: the pane takes them again.
    var onThemesChange: (() -> Void)?

    init(prefs: AppPrefsStore, folder: String) {
        self.prefs = prefs
        self.folder = folder
        library = ThemeLibrary(files: ThemeFolder.files(at: folder))
        resolve()
        // `resolve` sets it only for a change, and the theme of a fresh
        // launch is the one `Theme` starts with.
        showAppearance()
        systemWatch = DefaultsWatch(key: Self.interfaceStyleKey) { [weak self] in self?.resolve() }
        folderWatch = ThemeFolderWatch(path: folder) { [weak self] in self?.readFolder() }
    }

    var choice: ThemeChoice { prefs.values.theme }

    var inEffect: ThemeCatalog.Entry { Theme.entry }

    /// The theme chosen for an appearance: the saved one, or the standard
    /// one, also while the file of the saved one is away.
    func theme(for variant: ThemeVariant) -> ThemeCatalog.Entry {
        library.entry(prefs.values.themes[variant], for: variant)
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

    /// A folder that reads as before changes nothing. Nothing is saved: the
    /// file keeps the id of a theme whose file is away.
    private func readFolder() {
        let read = ThemeLibrary(files: ThemeFolder.files(at: folder))
        guard read != library else { return }
        library = read
        resolve()
        onThemesChange?()
    }

    /// Also what the watches run: a change of the Mac's appearance moves the
    /// theme only while the choice is `auto`, and saves nothing. The entry is
    /// compared whole: a file that was changed keeps its id.
    private func resolve() {
        let systemIsDark = ThemeChoice.systemIsDark(
            interfaceStyle: UserDefaults.standard.string(forKey: Self.interfaceStyleKey)
        )
        let entry = library.inEffect(choice: choice, themes: prefs.values.themes, systemIsDark: systemIsDark)
        guard entry != Theme.entry else { return }
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
