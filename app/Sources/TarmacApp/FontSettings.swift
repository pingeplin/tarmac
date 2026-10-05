import TarmacKit

/// The chosen fonts (specs 2610.0005, 2610.0006): what is saved for each
/// role, and the family and the size each role really uses, which is what
/// every view is given.
@MainActor
final class FontSettings {
    private let prefs: AppPrefsStore
    /// A role's family or size in effect changed: views that hold a font take
    /// it again.
    var onChange: (() -> Void)?

    init(prefs: AppPrefsStore) {
        self.prefs = prefs
        for role in FontRole.allCases {
            resolve(role)
            resolveSize(role)
        }
    }

    var saved: [FontRole: String] { prefs.values.fonts }

    func choose(_ family: String?, for role: FontRole) {
        guard family != saved[role] else { return }
        prefs.update { $0.fonts[role] = family }
        resolve(role)
        onChange?()
    }

    /// The size in effect, or nil for a role that has none.
    func size(for role: FontRole) -> Double? { Theme.fontSizes[role] }

    func chooseSize(_ size: Double, for role: FontRole) {
        guard let choice = role.sizeRule?.choice(size, saved: prefs.values.fontSizes[role]) else { return }
        prefs.update { $0.fontSizes[role] = choice }
        resolveSize(role)
        onChange?()
    }

    private func resolveSize(_ role: FontRole) {
        Theme.fontSizes[role] = role.sizeRule?.inEffect(saved: prefs.values.fontSizes[role])
    }

    /// Reads the one saved family from the Mac, not the whole font list.
    private func resolve(_ role: FontRole) {
        let saved = saved[role]
        Theme.fontFamilies[role] = role.familyInEffect(saved: saved, installed: saved.flatMap(InstalledFonts.family(named:)))
    }
}
