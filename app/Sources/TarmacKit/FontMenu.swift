import Foundation

/// What the Mac says of one font family. `fixedPitch` is the trait of its
/// regular upright face, the one a role would use.
public struct InstalledFamily: Equatable, Sendable {
    public let name: String
    public let fixedPitch: Bool

    public init(name: String, fixedPitch: Bool) {
        self.name = name
        self.fixedPitch = fixedPitch
    }

    /// One member of a family, as the font manager lists it: its weight on
    /// the manager's scale, where 5 is regular.
    public struct Face: Equatable, Sendable {
        public let weight: Int
        public let italic: Bool
        public let fixedPitch: Bool

        public init(weight: Int, italic: Bool, fixedPitch: Bool) {
            self.weight = weight
            self.italic = italic
            self.fixedPitch = fixedPitch
        }
    }

    /// A family from its members, in the order the Mac lists them; nil when
    /// it has none. Its regular face is the upright member whose weight is
    /// nearest 5, the first of them on a tie: Osaka lists its proportional
    /// face before Osaka-Mono. A family of italics only is judged by them.
    public init?(name: String, faces: [Face]) {
        let upright = faces.filter { !$0.italic }
        guard let regular = (upright.isEmpty ? faces : upright).min(by: { abs($0.weight - 5) < abs($1.weight - 5) })
        else { return nil }
        self.init(name: name, fixedPitch: regular.fixedPitch)
    }
}

/// The list one row of the Settings window shows, and the entry it selects
/// (spec 2610.0005). Entry 0 is the system default; the rest are `families`.
public struct FontMenu: Equatable, Sendable {
    public static let systemDefaultTitle = "System Default"

    public let families: [String]
    public let selected: Int

    public init(role: FontRole, installed: [InstalledFamily], saved: String?) {
        let listed = installed.filter { !$0.name.hasPrefix(".") && ($0.fixedPitch || !role.fixedPitchOnly) }
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
