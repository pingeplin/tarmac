import Foundation

/// A theme file of the user (spec 2610.0009): the Ghostty keys for the
/// terminal colours and, by choice, Tarmac's own keys for the chrome. `parse`
/// gives what the text holds, or why the file is refused.
///
/// The lines are read as Ghostty 1.3.1 reads them. The values are narrower: a
/// colour is hexadecimal, and an index is plain decimal. A used key with a
/// value that is not read refuses the whole file, because a theme with one
/// colour the user did not write is worse than a named bad line.
public enum ThemeFile {
    /// A chrome token a file can give, by the end of its key.
    public enum ChromeKey: String, CaseIterable, Sendable {
        case bg0, bg1, bg2, bg3, line
        case lineSoft = "line-soft"
        case liftBorder = "lift-border"
        case primeHeaderBg = "prime-header-bg"
        case text, muted, faint, prose, agent, amber, ok
        case consoleError = "console-error"

        public var fileKey: String { "tarmac-" + rawValue }
    }

    /// What a file gave. A colour it did not give has no entry.
    public struct Colours: Equatable, Sendable {
        public var background, foreground: UInt32
        public var cursor: UInt32?
        /// By index, 0 to 15 only.
        public var ansi: [Int: UInt32]
        public var chrome: [ChromeKey: UInt32]
        /// By index, 0 to 3 only.
        public var repo: [Int: UInt32]
    }

    public enum Refusal: Error, Equatable, Sendable {
        case unreadable
        case tooLarge
        case notText
        case value(line: Int, key: String)
        case missing(key: String)

        /// The words for a person, to follow the file's name.
        public var reason: String {
            switch self {
            case .unreadable: "cannot be read"
            case .tooLarge: "is larger than 64 KiB"
            case .notText: "is not UTF-8 text"
            case let .value(line, key): "line \(line): the value of \(key) cannot be read"
            case let .missing(key): "has no \(key)"
            }
        }
    }

    public static let sizeLimit = 65_536

    public static func parse(_ text: String) -> Result<Colours, Refusal> {
        // By scalar: a `\r\n` is one `Character`, and would hide its `\n`.
        var scalars = Scalars(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
        var draft = Draft()
        for (offset, line) in scalars.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = trimmed(line, of: lineEnds)
            guard let first = line.first, first != "#" else { continue }
            let (keyScalars, value) = cut(line)
            let key = string(keyScalars)
            guard let field = Field(key) else { continue }
            guard let value, draft.take(unquoted(value), for: field) else {
                return .failure(.value(line: offset + 1, key: key))
            }
        }
        guard let background = draft.background else { return .failure(.missing(key: "background")) }
        guard let foreground = draft.foreground else { return .failure(.missing(key: "foreground")) }
        return .success(Colours(
            background: background, foreground: foreground, cursor: draft.cursor,
            ansi: draft.ansi, chrome: draft.chrome, repo: draft.repo
        ))
    }

    private typealias Scalars = ArraySlice<Unicode.Scalar>

    private static let blanks: Set<Unicode.Scalar> = [" ", "\t"]
    private static let lineEnds: Set<Unicode.Scalar> = [" ", "\t", "\r"]
    private static let ansiCount = 16
    private static let repoCount = 4

    private enum Field {
        case background, foreground, cursor, palette, repo
        case chrome(ChromeKey)

        init?(_ key: String) {
            switch key {
            case "background": self = .background
            case "foreground": self = .foreground
            case "cursor-color": self = .cursor
            case "palette": self = .palette
            case "tarmac-repo": self = .repo
            default:
                guard let chrome = ChromeKey.allCases.first(where: { $0.fileKey == key }) else { return nil }
                self = .chrome(chrome)
            }
        }
    }

    private struct Draft {
        var background, foreground, cursor: UInt32?
        var ansi: [Int: UInt32] = [:]
        var chrome: [ChromeKey: UInt32] = [:]
        var repo: [Int: UInt32] = [:]

        /// Whether `value` was read. An empty one takes away what earlier
        /// lines gave for the field.
        mutating func take(_ value: Scalars, for field: Field) -> Bool {
            switch field {
            case .background: return Self.set(&background, value)
            case .foreground: return Self.set(&foreground, value)
            case .cursor:
                let unset = ["cell-foreground", "cell-background"].contains(string(value))
                return Self.set(&cursor, unset ? [] : value)
            case .chrome(let key): return Self.set(&chrome[key], value)
            case .palette: return Self.set(&ansi, value, limit: 255, kept: ansiCount)
            case .repo: return Self.set(&repo, value, limit: repoCount - 1, kept: repoCount)
            }
        }

        private static func set(_ colour: inout UInt32?, _ value: Scalars) -> Bool {
            guard !value.isEmpty else {
                colour = nil
                return true
            }
            guard let read = ThemeFile.colour(value) else { return false }
            colour = read
            return true
        }

        /// An entry `N=colour`. An index of `kept` or more, up to `limit`,
        /// must be a valid entry and gives nothing.
        private static func set(_ entries: inout [Int: UInt32], _ value: Scalars, limit: Int, kept: Int) -> Bool {
            guard !value.isEmpty else {
                entries = [:]
                return true
            }
            let (head, tail) = cut(value)
            guard let tail, let index = ThemeFile.index(head, limit: limit), let read = ThemeFile.colour(tail)
            else { return false }
            if index < kept { entries[index] = read }
            return true
        }
    }

    private static func string(_ scalars: Scalars) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    private static func trimmed(_ scalars: Scalars, of junk: Set<Unicode.Scalar>) -> Scalars {
        var rest = scalars
        while let first = rest.first, junk.contains(first) { rest = rest.dropFirst() }
        while let last = rest.last, junk.contains(last) { rest = rest.dropLast() }
        return rest
    }

    /// The parts before and after the first `=`, each trimmed of space and
    /// tab. With no `=` there is no second part.
    private static func cut(_ scalars: Scalars) -> (head: Scalars, tail: Scalars?) {
        guard let equals = scalars.firstIndex(of: "=") else { return (trimmed(scalars, of: blanks), nil) }
        return (trimmed(scalars[..<equals], of: blanks), trimmed(scalars[(equals + 1)...], of: blanks))
    }

    private static func unquoted(_ value: Scalars) -> Scalars {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return trimmed(value.dropFirst().dropLast(), of: blanks)
    }

    /// An optional `#` and then six or three ASCII hexadecimal digits.
    private static func colour(_ scalars: Scalars) -> UInt32? {
        let digits = scalars.first == "#" ? scalars.dropFirst() : scalars
        guard digits.count == 6 || digits.count == 3 else { return nil }
        var value: UInt32 = 0
        for scalar in digits {
            guard scalar.isASCII, let digit = Character(scalar).hexDigitValue else { return nil }
            value = value << 4 | UInt32(digit)
            if digits.count == 3 { value = value << 4 | UInt32(digit) }
        }
        return value
    }

    /// ASCII digits only, as a decimal number of at most `limit`.
    private static func index(_ scalars: Scalars, limit: Int) -> Int? {
        guard !scalars.isEmpty else { return nil }
        var value = 0
        for scalar in scalars {
            guard scalar.isASCII, let digit = Character(scalar).wholeNumberValue else { return nil }
            value = value * 10 + digit
            guard value <= limit else { return nil }
        }
        return value
    }
}

/// Every colour of a theme from what a file gave (spec 2610.0009). A colour
/// the file gave is never changed. A fill or a line it did not give is a
/// fixed mix of the terminal background and foreground, and a text or a mark
/// is moved towards white (a dark theme) or black (a light one) until it has
/// its floor of `PaletteCheck` on the three fills.
extension ThemeFile {
    /// UTF-8, then `parse`, then `palette(from:)`.
    public static func palette(of contents: Data) -> Result<Palette, Refusal> {
        guard let text = String(data: contents, encoding: .utf8) else { return .failure(.notText) }
        return parse(text).map(palette(from:))
    }

    public static func palette(from colours: Colours) -> Palette {
        let (ground, ink) = (colours.background, colours.foreground)
        let variant = Palette.variant(background: ground, foreground: ink)
        let standard = ThemeCatalog.standard(for: variant).palette.terminal.ansi
        let ansi = standard.indices.map { colours.ansi[$0] ?? standard[$0] }

        func fill(_ key: ChromeKey, _ dark: Double, _ light: Double) -> UInt32 {
            colours.chrome[key] ?? mix(ground, ink, variant == .dark ? dark : light)
        }
        let (bg0, bg1, bg2) = (fill(.bg0, -0.08, 0.10), fill(.bg1, -0.04, 0.05), fill(.bg2, 0.07, 0.15))
        let pole: UInt32 = variant == .dark ? 0xffffff : 0x000000
        func lift(_ colour: UInt32, _ floor: Double) -> UInt32 {
            (0...liftSteps).lazy.map { mix(colour, pole, Double($0) / Double(liftSteps)) }
                .first { lifted in [bg0, bg1, bg2].allSatisfy { Contrast.ratio(lifted, $0) >= floor } } ?? pole
        }
        func mark(_ key: ChromeKey, _ index: Int) -> UInt32 {
            colours.chrome[key] ?? lift(ansi[index], 3)
        }
        let agent = mark(.agent, 6)

        return Palette(
            bg0: bg0, bg1: bg1, bg2: bg2, bg3: fill(.bg3, 0.15, 0.23),
            line: fill(.line, 0.24, 0.36), lineSoft: fill(.lineSoft, 0.15, 0.25),
            liftBorder: fill(.liftBorder, 0.40, 0.55), primeHeaderBg: fill(.primeHeaderBg, 0.11, 0.20),
            text: colours.chrome[.text] ?? lift(ink, 4.5),
            muted: colours.chrome[.muted] ?? lift(mix(ink, ground, 0.25), 4.5),
            faint: colours.chrome[.faint] ?? mix(ink, ground, 0.45),
            prose: colours.chrome[.prose] ?? ink,
            agent: agent, amber: mark(.amber, 3), ok: mark(.ok, 2), consoleError: mark(.consoleError, 1),
            scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
            repoColors: repoSources.enumerated().map { colours.repo[$0.offset] ?? lift(ansi[$0.element], 3) },
            terminal: Palette.Terminal(
                foreground: ink, background: ground, cursor: colours.cursor ?? ink,
                selection: agent, selectionAlpha: 0.3, ansi: ansi
            )
        )
    }

    private static let liftSteps = 16
    /// The ANSI colour each repo colour starts from.
    private static let repoSources = [3, 2, 4, 5]

    /// On the 8-bit channels, in this order of operations: another order can
    /// round another way at a half.
    private static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        [16, 8, 0].reduce(0) { mixed, shift in
            let (from, to) = (Double(a >> shift & 0xff), Double(b >> shift & 0xff))
            return mixed | UInt32(min(max((from + (to - from) * t).rounded(), 0), 255)) << shift
        }
    }
}
