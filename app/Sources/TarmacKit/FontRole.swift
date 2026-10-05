/// A place Tarmac sets text in, and so a font the user can choose (spec
/// 2610.0005).
public enum FontRole: String, CaseIterable, Sendable {
    case terminal, interface, document

    public var prefsKey: String { rawValue + "_font" }

    /// The role's name on its Settings row.
    public var title: String {
        switch self {
        case .terminal: "Terminal"
        case .interface: "Interface"
        case .document: "Document"
        }
    }

    /// The terminal needs a cell grid, and the chrome is laid out for one
    /// advance width.
    public var fixedPitchOnly: Bool { self != .document }

    /// The saved family when this role can use it, or nil for the system
    /// default. `installed` is what the Mac says of that family, nil when it
    /// has none.
    public func familyInEffect(saved: String?, installed: InstalledFamily?) -> String? {
        guard let saved, let installed, installed.name == saved, installed.isChoosable(for: self) else { return nil }
        return saved
    }

    /// Whether `name` can be saved and handed to CSS: not empty, and no
    /// control character.
    static func isFamilyName(_ name: String) -> Bool {
        !name.isEmpty && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
