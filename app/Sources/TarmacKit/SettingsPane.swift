/// The sections of the Settings window, in the order of its sidebar (spec
/// 2610.0007).
public enum SettingsPane: String, CaseIterable, Sendable {
    case fonts, theme

    /// The section's name in the sidebar.
    public var title: String {
        switch self {
        case .fonts: "Fonts"
        case .theme: "Theme"
        }
    }
}
