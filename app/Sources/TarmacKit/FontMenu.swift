import Foundation

/// The list one row of the Settings window shows, and the entry it selects
/// (spec 2610.0005). Entry 0 is the system default; the rest are `families`.
public struct FontMenu: Equatable, Sendable {
    public static let systemDefaultTitle = "System Default"

    public let families: [String]
    public let selected: Int

    public init(role: FontRole, installed: [InstalledFamily], saved: String?) {
        let listed = installed.filter { $0.isChoosable(for: role) }
        // Not the localized compare: the order must not follow the user's locale.
        families = Set(listed.map(\.name)).sorted {
            switch $0.caseInsensitiveCompare($1) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0 < $1
            }
        }
        selected = saved.flatMap(families.firstIndex(of:)).map { $0 + 1 } ?? 0
    }

    public var titles: [String] { [Self.systemDefaultTitle] + families }

    /// The family at `index`, or nil for the system default and for an index
    /// outside the list.
    public func choice(at index: Int) -> String? {
        families.indices.contains(index - 1) ? families[index - 1] : nil
    }
}
