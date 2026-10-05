import TarmacKit

/// The chosen fonts (spec 2610.0005): what is saved for each role, and the
/// family each role really uses, which is what every view is given.
@MainActor
final class FontSettings {
    private let prefs: AppPrefsStore
    /// A role's family in effect changed: views that hold a font take it again.
    var onChange: (() -> Void)?

    init(prefs: AppPrefsStore) {
        self.prefs = prefs
        for role in FontRole.allCases { resolve(role) }
    }

    var saved: [FontRole: String] { prefs.values.fonts }

    func choose(_ family: String?, for role: FontRole) {
        guard family != saved[role] else { return }
        prefs.update { $0.fonts[role] = family }
        resolve(role)
        onChange?()
    }

    /// Reads the one saved family from the Mac, not the whole font list.
    private func resolve(_ role: FontRole) {
        let saved = saved[role]
        Theme.fontFamilies[role] = role.familyInEffect(saved: saved, installed: saved.flatMap(InstalledFonts.family(named:)))
    }
}
