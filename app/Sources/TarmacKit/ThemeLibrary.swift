import Foundation

/// The themes Tarmac has at one moment (spec 2610.0009): the built-in ones
/// and those of the user's files, in the order of the Theme pane's list, and
/// which theme an id names. A value: two libraries are equal when their
/// themes and their refused files are, so a file whose change gives the same
/// palette changes nothing.
public struct ThemeLibrary: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public let name: String
        public let contents: Result<Data, ThemeFile.Refusal>
    }

    public struct Refused: Equatable, Sendable {
        public let file: String
        public let refusal: ThemeFile.Refusal

        public var detail: String { "\(file): \(refusal.reason)" }
    }

    /// What the id of a file theme starts with. No built-in id holds a `:`,
    /// so a file can have the name of a built-in theme.
    public static let filePrefix = "file:"
    public static let shipped = ThemeLibrary(files: [])

    public let fileThemes: [ThemeCatalog.Entry]
    public let refused: [Refused]

    /// Whether a file of that name is read at all: not a hidden file, not an
    /// editor's backup, and a name that can be an id.
    public static func reads(_ fileName: String) -> Bool {
        ThemeCatalog.isID(fileName) && !fileName.hasPrefix(".") && !fileName.hasSuffix("~")
    }

    public init(files: [File]) {
        var themes: [ThemeCatalog.Entry] = []
        var refused: [Refused] = []
        for file in files {
            switch file.contents.flatMap(ThemeFile.palette(of:)) {
            case .success(let palette):
                themes.append(ThemeCatalog.Entry(id: Self.filePrefix + file.name, title: file.name, palette: palette))
            case .failure(let refusal):
                refused.append(Refused(file: file.name, refusal: refusal))
            }
        }
        fileThemes = themes.sorted { Self.precedes($0.title, $1.title) }
        self.refused = refused.sorted { Self.precedes($0.file, $1.file) }
    }

    /// The order of the list.
    public var all: [ThemeCatalog.Entry] { ThemeCatalog.all + fileThemes }

    /// The theme with that id, compared exactly, if there is one.
    public func theme(_ id: String?) -> ThemeCatalog.Entry? {
        all.first { $0.id == id }
    }

    /// The theme with that id, whatever its variant, or the standard one of
    /// `variant`.
    public func entry(_ id: String?, for variant: ThemeVariant) -> ThemeCatalog.Entry {
        theme(id) ?? ThemeCatalog.standard(for: variant)
    }

    public func inEffect(
        choice: ThemeChoice, themes: [ThemeVariant: String], systemIsDark: Bool
    ) -> ThemeCatalog.Entry {
        let variant = choice.inEffect(systemIsDark: systemIsDark)
        return entry(themes[variant], for: variant)
    }

    /// With no regard to letter case, and then by the names themselves.
    private static func precedes(_ a: String, _ b: String) -> Bool {
        (a.lowercased(), a) < (b.lowercased(), b)
    }
}
