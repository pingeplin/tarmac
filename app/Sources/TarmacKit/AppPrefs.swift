import Foundation

/// The app's own tiny preference file (spec 2609.0016).
///
/// It lives beside the daemon socket, so the dev and installed apps cannot share
/// one: `<worktree>/.dev/` under `make run`, the per-channel support dir
/// otherwise. Anything unreadable means the guard is ON: a preference file is
/// never a reason to quit the cockpit by accident.
///
/// With no font chosen the format, `{"warn_before_quit": <bool>}`, is the Tauri
/// app's `app-prefs.json` byte for byte. A chosen font adds its role's key
/// (spec 2610.0005), a chosen size its own (spec 2610.0006), an appearance
/// that is not the standard one the key `theme` (spec 2610.0007), and a theme
/// that is not the standard one of its appearance that appearance's key (spec
/// 2610.0008). The parse and
/// encode decisions are pure; `load` and `save` are the two thin file
/// operations.
public enum AppPrefs {
    public static let fileName = "app-prefs.json"

    /// The whole file. Every writer saves all of it, so no preference can drop
    /// another's key.
    public struct Values: Equatable, Sendable {
        public var warnBeforeQuit: Bool
        /// The family chosen for a role; no entry is the system default.
        public var fonts: [FontRole: String]
        /// The size chosen for a role; no entry is the role's standard.
        public var fontSizes: [FontRole: Double]
        /// The appearance chosen; no key in the file is the standard one.
        public var theme: ThemeChoice
        /// The id of the theme chosen for an appearance. No entry, and the id
        /// of the appearance's standard theme, both mean the standard one;
        /// neither is written. An id that no theme has is kept: it is
        /// resolved when it is used (`ThemeLibrary.entry`).
        public var themes: [ThemeVariant: String]

        public init(
            warnBeforeQuit: Bool = true, fonts: [FontRole: String] = [:], fontSizes: [FontRole: Double] = [:],
            theme: ThemeChoice = .standard, themes: [ThemeVariant: String] = [:]
        ) {
            self.warnBeforeQuit = warnBeforeQuit
            self.fonts = fonts
            self.fontSizes = fontSizes
            self.theme = theme
            self.themes = themes
        }
    }

    /// Each key is read on its own: one of the wrong type is that key's
    /// default and nothing more.
    private struct Stored: Decodable {
        let values: Values

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }

            init(_ name: String) { stringValue = name }
            init?(stringValue: String) { self.init(stringValue) }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let object = try decoder.container(keyedBy: Key.self)
            var values = Values(warnBeforeQuit: (try? object.decode(Bool.self, forKey: Key("warn_before_quit"))) ?? true)
            for role in FontRole.allCases {
                guard let name = try? object.decode(String.self, forKey: Key(role.prefsKey)),
                    FontRole.isFamilyName(name)
                else { continue }
                values.fonts[role] = name
            }
            for role in FontRole.allCases {
                guard let rule = role.sizeRule,
                    let size = try? object.decode(Double.self, forKey: Key(role.sizePrefsKey)), rule.accepts(size)
                else { continue }
                values.fontSizes[role] = size
            }
            if let name = try? object.decode(String.self, forKey: Key(ThemeChoice.prefsKey)) {
                values.theme = ThemeChoice(rawValue: name) ?? .standard
            }
            for variant in ThemeVariant.allCases {
                let id = try? object.decode(String.self, forKey: Key(variant.prefsKey))
                values.themes[variant] = ThemeCatalog.saved(id, for: variant)
            }
            self.values = values
        }
    }

    public static func path(besideSocket socket: String) -> String {
        ((socket as NSString).deletingLastPathComponent as NSString).appendingPathComponent(fileName)
    }

    /// Whether ⌘Q is guarded, as the file says: `decode`'s answer for that key.
    public static func warnBeforeQuit(from contents: Data?) -> Bool {
        decode(contents).warnBeforeQuit
    }

    /// The file's values. Missing, unreadable, malformed or not an object all
    /// read as the defaults, so the guard is on.
    ///
    /// "Malformed" is meant as what serde_json rejects, so the Tauri app and this
    /// one agree on any file either of them wrote. `JSONDecoder` is more
    /// forgiving, so `StrictJSON` vets the bytes first: anything but UTF-8 (a BOM, UTF-16, UTF-32), a raw
    /// control character in a string, a trailing comma, a leading zero, a number
    /// that overflows a `Double`, a lone surrogate or unknown escape, and nesting
    /// past 127 levels all read as damaged. Only then is the file decoded, and
    /// strictly: `JSONSerialization` would bridge a `0` to `false`, and only a
    /// real JSON boolean may turn the guard off.
    ///
    /// Known differences, none reachable from a file the app writes: a duplicated
    /// `warn_before_quit` key (serde_json keeps the last value, `JSONDecoder` the
    /// first); a number within rounding distance of the largest `Double`, where
    /// serde_json's own conversion is not correctly rounded; and an object whose
    /// first key is serde_json's internal `$serde_json::private::RawValue`.
    public static func decode(_ contents: Data?) -> Values {
        guard let contents, StrictJSON.isValid(contents),
            let stored = try? JSONDecoder().decode(Stored.self, from: contents)
        else { return Values() }
        return stored.values
    }

    /// Written as a literal, not through an encoder: QA reads these exact bytes.
    /// A name `decode` would refuse is left out, because written raw it would
    /// damage the file, and a damaged file turns the guard back on. So is a
    /// size it would refuse. Every family is written before every size, then
    /// the appearance, then the theme of each appearance. A standard one is not
    /// written, so a file with nothing chosen keeps the bytes it had before
    /// there was a choice. A theme id can come from a file's name, so it is
    /// written as a JSON string, as a family is.
    public static func encode(_ values: Values) -> Data {
        var json = #"{"warn_before_quit":\#(values.warnBeforeQuit)"#
        for role in FontRole.allCases {
            guard let name = values.fonts[role], FontRole.isFamilyName(name) else { continue }
            json += #","\#(role.prefsKey)":\#(JSONValue.string(name).jsonString)"#
        }
        for role in FontRole.allCases {
            guard let rule = role.sizeRule, let size = values.fontSizes[role], rule.accepts(size) else { continue }
            json += #","\#(role.sizePrefsKey)":\#(JSONValue.number(size).jsonString)"#
        }
        if values.theme != .standard {
            json += #","\#(ThemeChoice.prefsKey)":"\#(values.theme.rawValue)""#
        }
        for variant in ThemeVariant.allCases {
            guard let id = ThemeCatalog.saved(values.themes[variant], for: variant) else { continue }
            json += #","\#(variant.prefsKey)":\#(JSONValue.string(id).jsonString)"#
        }
        return Data((json + "}").utf8)
    }

    /// Read the file. Any IO failure is the same answer as an absent file.
    public static func load(from path: String) -> Values {
        decode(try? Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Save through a temp file, so a crash mid-write cannot leave a
    /// half-written file that would then read as "guard on" forever. The rename
    /// replaces an existing file, which `FileManager.moveItem` refuses to do.
    /// Best effort: the in-memory values are what this session obeys either way.
    public static func save(_ values: Values, to path: String) throws {
        let temporary = path + ".tmp"
        try encode(values).write(to: URL(fileURLWithPath: temporary))
        guard rename(temporary, path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
