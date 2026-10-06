/// An appearance, and which of the two a theme is (specs 2610.0007,
/// 2610.0008): a light theme can be chosen for the dark appearance.
public enum ThemeVariant: String, CaseIterable, Sendable {
    case light, dark

    /// The key the theme chosen for this appearance is saved under.
    public var prefsKey: String { "theme_\(rawValue)" }

    /// The appearance's name in a mark of the list and in the title of a box.
    public var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
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

    /// Whether the Mac's appearance is dark, from the value of the global
    /// preference `AppleInterfaceStyle`: the Mac writes exactly `"Dark"`, and
    /// no value when it is light.
    public static func systemIsDark(interfaceStyle: String?) -> Bool {
        interfaceStyle == "Dark"
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
