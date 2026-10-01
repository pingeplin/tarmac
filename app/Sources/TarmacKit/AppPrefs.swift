import Foundation

/// The app's own tiny preference file (spec 2609.0016).
///
/// It lives beside the daemon socket, so the dev and installed apps cannot share
/// one: `<worktree>/.dev/` under `make run`, the per-channel support dir
/// otherwise. Anything unreadable means the guard is ON: a preference file is
/// never a reason to quit the cockpit by accident.
///
/// The format, `{"warn_before_quit": <bool>}`, is the Tauri app's `app-prefs.json`
/// byte for byte, so either app reads the other's file. The parse and encode
/// decisions are pure; `load` and `save` are the two thin file operations.
public enum AppPrefs {
    public static let fileName = "app-prefs.json"

    private struct Stored: Decodable {
        let warnBeforeQuit: Bool?

        enum CodingKeys: String, CodingKey {
            case warnBeforeQuit = "warn_before_quit"
        }
    }

    public static func path(besideSocket socket: String) -> String {
        ((socket as NSString).deletingLastPathComponent as NSString).appendingPathComponent(fileName)
    }

    /// Whether ⌘Q is guarded, as the file says. Missing, unreadable, malformed
    /// or the wrong type all read as `true`. Decoded strictly: `JSONSerialization`
    /// would bridge a `0` to `false`, and only a real JSON boolean may turn the
    /// guard off. A byte-order mark is damage too, as it is for serde_json;
    /// `JSONDecoder` alone would skip it.
    public static func warnBeforeQuit(from contents: Data?) -> Bool {
        guard let contents, !contents.starts(with: byteOrderMark),
            let stored = try? JSONDecoder().decode(Stored.self, from: contents)
        else { return true }
        return stored.warnBeforeQuit ?? true
    }

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Written as a literal, not through an encoder: QA reads these exact bytes.
    public static func encode(warnBeforeQuit: Bool) -> Data {
        Data(#"{"warn_before_quit":\#(warnBeforeQuit)}"#.utf8)
    }

    /// Read the toggle. Any IO failure is the same answer as an absent file.
    public static func load(from path: String) -> Bool {
        warnBeforeQuit(from: try? Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Save the toggle through a temp file, so a crash mid-write cannot leave a
    /// half-written file that would then read as "guard on" forever. The rename
    /// replaces an existing file, which `FileManager.moveItem` refuses to do.
    /// Best effort: the in-memory toggle is what this session obeys either way.
    public static func save(warnBeforeQuit: Bool, to path: String) throws {
        let temporary = path + ".tmp"
        try encode(warnBeforeQuit: warnBeforeQuit).write(to: URL(fileURLWithPath: temporary))
        guard rename(temporary, path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
