import Foundation

/// The rules of the Theme pane's list and showcase (specs 2610.0008,
/// 2610.0009): the state of an "Apply to" box and the theme it gives, the
/// marks of a row, the contrast note, the line about the theme files, the
/// shown theme after the themes changed, and the fixed words. What is shown
/// and what is chosen are arguments: the pane holds the first and
/// `ThemeSettings` the second.
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
    /// of its row. `chosen` gives the theme of an appearance, as `box` is
    /// given it: an appearance with nothing saved has its standard theme.
    public static func marks(
        of entry: ThemeCatalog.Entry, chosen: (ThemeVariant) -> ThemeCatalog.Entry
    ) -> [ThemeVariant] {
        ThemeVariant.allCases.filter { chosen($0).id == entry.id }
    }

    /// The line under the boxes: how many terminal colours the detector
    /// found under their floor, and then how many chrome colours. A chrome
    /// colour is counted once, on however many fills it is found.
    public static func contrastNote(_ palette: Palette) -> String {
        let findings = PaletteCheck.findings(palette)
        let terminal = count(
            findings.filter { $0.part == .terminal }.count,
            one: "1 terminal colour has low contrast on the background.",
            many: "terminal colours have low contrast on the background."
        )
        let chrome = count(
            Set(findings.filter { $0.part == .chrome }.map(\.subject)).count,
            one: "1 chrome colour has low contrast.", many: "chrome colours have low contrast."
        )
        return [terminal ?? "Every terminal colour passes the contrast floors.", chrome].compactMap { $0 }
            .joined(separator: " ")
    }

    /// One line for each finding, in the detector's order: what the note
    /// counts, by name.
    public static func contrastDetail(_ palette: Palette) -> [String] {
        PaletteCheck.findings(palette).map {
            let floor = $0.floor == $0.floor.rounded() ? String(Int($0.floor)) : String($0.floor)
            return "\($0.subject) on \($0.ground): \(String(format: "%.2f", $0.ratio)) (floor \(floor))"
        }
    }

    /// The tooltip that names what a line counts: each detail on a line of
    /// its own, and no tooltip with nothing to name.
    public static func toolTip(_ details: [String]) -> String? {
        details.isEmpty ? nil : details.joined(separator: "\n")
    }

    /// The line under the list: the themes the files gave, and the files
    /// that are no theme.
    public static func filesNote(themes: Int, refused: Int) -> String {
        let parts = [
            count(themes, one: "1 theme from a file.", many: "themes from files."),
            count(refused, one: "1 file was not read.", many: "files were not read."),
        ].compactMap { $0 }
        return parts.isEmpty ? "No theme files." : parts.joined(separator: " ")
    }

    private static func count(_ number: Int, one: String, many: String) -> String? {
        switch number {
        case 0: nil
        case 1: one
        default: "\(number) \(many)"
        }
    }

    /// The shown theme after the themes changed: the theme that has its id
    /// now, with the colours it has now, or the theme in effect when the
    /// file is gone.
    public static func shown(
        _ shown: ThemeCatalog.Entry, in library: ThemeLibrary, inEffect: ThemeCatalog.Entry
    ) -> ThemeCatalog.Entry {
        library.theme(shown.id) ?? inEffect
    }

    public static func boxTitle(for variant: ThemeVariant) -> String {
        "Apply to \(variant.title)"
    }

    /// What the theme is, beside its title in the showcase.
    public static func caption(of entry: ThemeCatalog.Entry) -> String {
        "\(entry.variant.rawValue) theme" + (entry.isFromFile ? ", from a file" : "")
    }
}
