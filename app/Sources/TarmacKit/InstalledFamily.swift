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

    /// Whether `role` can be set in this family. A name that begins with a
    /// dot is a hidden system family: it resolves, but no list shows it.
    public func isChoosable(for role: FontRole) -> Bool {
        !name.hasPrefix(".") && (fixedPitch || !role.fixedPitchOnly)
    }
}
