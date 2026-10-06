/// An appearance, and which of the two a theme is for (specs 2610.0007,
/// 2610.0008).
public enum ThemeVariant: String, CaseIterable, Sendable {
    case light, dark

    /// The key the theme chosen for this appearance is saved under.
    public var prefsKey: String { "theme_\(rawValue)" }

    /// The label of this appearance's row in the Theme pane.
    public var rowTitle: String {
        switch self {
        case .light: "Light theme"
        case .dark: "Dark theme"
        }
    }
}

/// The appearance the user chose, in the order of the Settings tiles (spec
/// 2610.0007). `auto` is the one that fits the macOS appearance.
public enum ThemeChoice: String, CaseIterable, Sendable {
    case auto, light, dark

    public static let standard = ThemeChoice.dark
    public static let prefsKey = "theme"

    /// The choice's name under its tile.
    public var title: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public func inEffect(systemIsDark: Bool) -> ThemeVariant {
        switch self {
        case .auto: systemIsDark ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }

    /// The variants the choice's tile pictures, from the left: each one it can
    /// put in effect, light first.
    public var pictured: [ThemeVariant] {
        [ThemeVariant.light, .dark].filter { inEffect(systemIsDark: $0 == .dark) == $0 }
    }
}
