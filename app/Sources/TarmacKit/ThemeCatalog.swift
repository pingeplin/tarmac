/// The themes Tarmac ships (spec 2610.0008), in the order of the Theme pane's
/// list, and the pure rules over them. Any theme can be chosen for either
/// appearance: a theme's variant says what it is, not where it can be chosen.
/// Which theme an id names is `ThemeLibrary`'s rule: a file of the user can
/// give a theme too (spec 2610.0009).
public enum ThemeCatalog {
    public struct Entry: Equatable, Sendable {
        /// What the file and the snapshot hold.
        public let id: String
        /// What the list and the showcase show.
        public let title: String
        public let palette: Palette

        public var variant: ThemeVariant { palette.variant }
        /// Whether a file of the user gave it (spec 2610.0009).
        public var isFromFile: Bool { id.hasPrefix(ThemeLibrary.filePrefix) }
    }

    /// Whether `id` can be the id of a theme: a text the file can hold, by
    /// the rule of a family name.
    static func isID(_ id: String) -> Bool {
        FontRole.isFamilyName(id)
    }

    private static let breezeLight = Entry(id: "breeze-light", title: "Breeze Light", palette: .breezeLight)
    private static let breezeDark = Entry(id: "breeze-dark", title: "Breeze Dark", palette: .breezeDark)

    public static let all = [
        breezeLight,
        breezeDark,
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
        case .light: breezeLight
        case .dark: breezeDark
        }
    }

    /// The id the file holds for `variant`: any well-formed id that is not
    /// that of the appearance's standard theme. Whether a theme has the id is
    /// not asked: a file theme whose file is away for a time keeps its key
    /// (spec 2610.0009), as a font that is not installed keeps its own.
    public static func saved(_ id: String?, for variant: ThemeVariant) -> String? {
        guard let id, isID(id), id != standard(for: variant).id else { return nil }
        return id
    }
}
