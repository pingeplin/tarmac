/// The themes Tarmac has (spec 2610.0008), in the order of the pop-ups, and
/// the pure rules over them.
public enum ThemeCatalog {
    public struct Entry: Equatable, Sendable {
        /// What the file and the snapshot hold.
        public let id: String
        /// What a pop-up shows.
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

    /// The themes an appearance can have, in the order of its pop-up.
    public static func offered(for variant: ThemeVariant) -> [Entry] {
        all.filter { $0.variant == variant }
    }

    /// The theme of an appearance with nothing chosen: Breeze, the first one
    /// it is offered.
    public static func standard(for variant: ThemeVariant) -> Entry {
        offered(for: variant)[0]
    }

    /// The offered theme with that id, compared exactly, or the standard one.
    public static func entry(_ id: String?, for variant: ThemeVariant) -> Entry {
        offered(for: variant).first { $0.id == id } ?? standard(for: variant)
    }

    public static func inEffect(
        choice: ThemeChoice, themes: [ThemeVariant: String], systemIsDark: Bool
    ) -> Entry {
        let variant = choice.inEffect(systemIsDark: systemIsDark)
        return entry(themes[variant], for: variant)
    }
}
