import TarmacKit

/// The chosen side of every markdown card's sidebar (spec 2611.0025 D15).
@MainActor
final class DocumentSettings {
    private let prefs: AppPrefsStore
    /// The side changed: every markdown card takes it again.
    var onChange: (() -> Void)?

    init(prefs: AppPrefsStore) {
        self.prefs = prefs
        resolve()
    }

    var side: DocSidebar.Side { prefs.values.docSidebarSide }

    func choose(_ side: DocSidebar.Side) {
        guard side != self.side else { return }
        prefs.update { $0.docSidebarSide = side }
        resolve()
        onChange?()
    }

    private func resolve() {
        Theme.docSidebarSide = side
    }
}
