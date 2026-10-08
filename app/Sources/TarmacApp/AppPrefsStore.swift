import TarmacKit

/// The one owner of `app-prefs.json`: every preference is read from here and
/// saved through here, whole, so no writer can drop another's key. The file's
/// place is `AppPrefs.path`'s. A file an older build left beside the daemon
/// socket is copied there once; when the copy fails the old file is not read,
/// and the standard values are in effect.
@MainActor
final class AppPrefsStore {
    private(set) var values: AppPrefs.Values
    private let path: String

    init(path: String, legacy: String) {
        self.path = path
        do {
            try AppPrefs.migrate(from: legacy, to: path)
        } catch {
            Log.stderr("could not bring app prefs from \(legacy): \(error)")
        }
        values = AppPrefs.load(from: path)
    }

    func update(_ change: (inout AppPrefs.Values) -> Void) {
        change(&values)
        do {
            try AppPrefs.save(values, to: path)
        } catch {
            // This session obeys the change either way; only the next launch
            // misses it.
            Log.stderr("could not save app prefs: \(error)")
        }
    }
}
