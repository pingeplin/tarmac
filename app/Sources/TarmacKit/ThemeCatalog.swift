/// The themes Tarmac has (spec 2610.0008), in the order of the Theme pane's
/// list, and the pure rules over them. Any theme can be chosen for either
/// appearance: a theme's variant says what it is, not where it can be chosen.
public enum ThemeCatalog {
    public struct Entry: Equatable, Sendable {
        /// What the file and the snapshot hold.
        public let id: String
        /// What the list and the showcase show.
        public let title: String
        public let palette: Palette

        public var variant: ThemeVariant { palette.variant }
    }

    public static let all = [
        Entry(id: "breeze-light", title: "Breeze Light", palette: .breezeLight),
        Entry(id: "breeze-dark", title: "Breeze Dark", palette: .breezeDark),
        Entry(id: "catppuccin-latte", title: "Catppuccin Latte", palette: .catppuccinLatte),
        Entry(id: "catppuccin-mocha", title: "Catppuccin Mocha", palette: .catppuccinMocha),
        Entry(id: "github-light", title: "GitHub Light", palette: .githubLight),
        Entry(id: "github-dark", title: "GitHub Dark", palette: .githubDark),
        Entry(id: "solarized-light", title: "Solarized Light", palette: .solarizedLight),
        Entry(id: "solarized-dark", title: "Solarized Dark", palette: .solarizedDark),
    ]

    /// The theme of an appearance with nothing chosen: Breeze.
    public static func standard(for variant: ThemeVariant) -> Entry {
        switch variant {
        case .light: all[0]
        case .dark: all[1]
        }
    }

    /// The theme with that id, compared exactly and whatever its variant, or
    /// the standard one of `variant`.
    public static func entry(_ id: String?, for variant: ThemeVariant) -> Entry {
        all.first { $0.id == id } ?? standard(for: variant)
    }

    public static func inEffect(
        choice: ThemeChoice, themes: [ThemeVariant: String], systemIsDark: Bool
    ) -> Entry {
        let variant = choice.inEffect(systemIsDark: systemIsDark)
        return entry(themes[variant], for: variant)
    }
}
