/// The theme whose palette the app holds (spec 2610.0007).
public enum ThemeVariant: String, Sendable { case light, dark }

/// The theme the user chose, in the order of the Settings tiles (spec
/// 2610.0007). `auto` is the variant that fits the macOS appearance.
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
}
