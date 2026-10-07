/// The rules of the Theme pane's list and showcase (spec 2610.0008): the
/// state of an "Apply to" box and the theme it gives, the marks of a row, the
/// contrast note, and the fixed words. What is shown and what is chosen are
/// arguments: the pane holds the first and `ThemeSettings` the second.
public enum ThemeBrowser {
    public struct Box: Equatable, Sendable {
        public let isOn: Bool
        public let isEnabled: Bool
    }

    /// The "Apply to" box of `variant` while `shown` is in the showcase and
    /// `chosen` is the theme chosen for `variant`. The box of an appearance's
    /// standard theme cannot be cleared: there is no theme to go back to.
    public static func box(
        shown: ThemeCatalog.Entry, chosen: ThemeCatalog.Entry, for variant: ThemeVariant
    ) -> Box {
        let isOn = shown.id == chosen.id
        return Box(isOn: isOn, isEnabled: !(isOn && shown.id == ThemeCatalog.standard(for: variant).id))
    }

    /// The theme `variant` has after its box is set (`on`) or cleared with
    /// `shown` in the showcase.
    public static func toggled(
        shown: ThemeCatalog.Entry, on: Bool, for variant: ThemeVariant
    ) -> ThemeCatalog.Entry {
        on ? shown : ThemeCatalog.standard(for: variant)
    }

    /// The appearances whose chosen theme `entry` is, light first: the marks
    /// of its row. `themes` holds no entry for a standard theme, so each
    /// appearance is asked for its theme, not for its saved id.
    public static func marks(of entry: ThemeCatalog.Entry, themes: [ThemeVariant: String]) -> [ThemeVariant] {
        ThemeVariant.allCases.filter { ThemeCatalog.entry(themes[$0], for: $0).id == entry.id }
    }

    /// The line under the boxes: how many terminal colours the detector
    /// found under their floor. A chrome finding is not counted.
    public static func contrastNote(_ palette: Palette) -> String {
        switch PaletteCheck.findings(palette).filter({ $0.part == .terminal }).count {
        case 0: "Every terminal colour passes the contrast floors."
        case 1: "1 terminal colour has low contrast on the background."
        case let count: "\(count) terminal colours have low contrast on the background."
        }
    }

    public static func boxTitle(for variant: ThemeVariant) -> String {
        "Apply to \(variant.title)"
    }

    /// What the theme is, beside its title in the showcase.
    public static func caption(of entry: ThemeCatalog.Entry) -> String {
        "\(entry.variant.rawValue) theme"
    }
}
