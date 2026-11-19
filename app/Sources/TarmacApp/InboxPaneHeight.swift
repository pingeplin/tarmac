import TarmacKit

/// The inbox preview pane's height the user set (spec 2611.0018 D8), kept in
/// `app-prefs.json`; nil is the standard.
@MainActor
final class InboxPaneHeight {
    private let prefs: AppPrefsStore

    init(prefs: AppPrefsStore) {
        self.prefs = prefs
    }

    var wanted: Double? {
        get { prefs.values.inboxPreviewHeight }
        set {
            // A held grip key repeats; the file is written only for a change.
            guard newValue != wanted else { return }
            prefs.update { $0.inboxPreviewHeight = newValue }
        }
    }
}
