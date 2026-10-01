import Foundation
import TarmacKit

/// Sends a board's layout snapshot once the board has been still for the
/// debounce: one timer per board (`PendingPersists`), so a background board's
/// change is neither lost nor delayed by the board being panned.
@MainActor
final class LayoutPersister {
    private var pending = PendingPersists()
    private let send: (String) -> Void

    init(send: @escaping (String) -> Void) {
        self.send = send
    }

    func schedule(_ boardID: String) {
        let token = pending.schedule(boardID)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(PendingPersists.debounceMs)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pending.fire(boardID, token: token) else { return }
                self.send(boardID)
            }
        }
    }

    /// Sends every snapshot still owed, now.
    func flush() {
        for boardID in pending.flushAll() {
            send(boardID)
        }
    }
}
