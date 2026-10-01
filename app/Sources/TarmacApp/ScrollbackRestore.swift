import Foundation
import TarmacKit

/// Runs `ScrollbackGate` for the app: asks the daemon for a mounted card's
/// history, arms the deadline, and hands on whatever the gate lets through.
@MainActor
final class ScrollbackRestore {
    private var gate = ScrollbackGate()
    private let request: (String) -> Void
    /// `history` is true when the chunks are everything the card should show —
    /// the daemon's ring, or what was held when no ring came — rather than live
    /// output to append.
    private let deliver: (_ termID: String, _ chunks: [Data], _ history: Bool) -> Void

    init(
        request: @escaping (String) -> Void,
        deliver: @escaping (_ termID: String, _ chunks: [Data], _ history: Bool) -> Void
    ) {
        self.request = request
        self.deliver = deliver
    }

    /// A terminal card was created, or is about to be sent its history again.
    func mount(_ termID: String) {
        let generation = gate.attach(termID)
        request(termID)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ScrollbackGate.awaitTimeoutMs)) { [weak self] in
            MainActor.assumeIsolated { self?.expire(termID, generation) }
        }
    }

    func output(_ termID: String, _ bytes: Data) {
        guard let shown = gate.output(termID, bytes) else { return }
        deliver(termID, [shown], false)
    }

    func reply(_ termID: String, _ bytes: Data) {
        guard let ring = gate.scrollback(termID, bytes) else { return }
        deliver(termID, [ring], true)
    }

    /// The card is gone; nothing held for it is shown.
    func unmount(_ termID: String) {
        gate.forget(termID)
    }

    func socketLost() {
        for (termID, chunks) in gate.clearAwaiting() {
            deliver(termID, chunks, true)
        }
    }

    private func expire(_ termID: String, _ generation: UInt64) {
        guard let held = gate.expire(termID, generation: generation) else { return }
        deliver(termID, held, true)
    }
}
