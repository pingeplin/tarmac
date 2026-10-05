import TarmacKit

/// The one owner of `app-prefs.json`: every preference is read from here and
/// saved through here, whole, so no writer can drop another's key. The file
/// sits beside the daemon socket — the one location that already separates a
/// dev app from the installed one, which share a bundle id.
@MainActor
final class AppPrefsStore {
    private(set) var values: AppPrefs.Values
    private let path: String

    init(path: String) {
        self.path = path
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
