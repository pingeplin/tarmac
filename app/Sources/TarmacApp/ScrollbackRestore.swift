import Foundation
import TarmacKit

/// Runs `ScrollbackGate` for the app: asks the daemon for a mounted card's
/// history, arms the deadline, and hands on whatever the gate lets through.
@MainActor
final class ScrollbackRestore {
    private var gate = ScrollbackGate()
    private let request: (String) -> Void
    private let deliver: (_ termID: String, ScrollbackGate.Release) -> Void

    init(
        request: @escaping (String) -> Void,
        deliver: @escaping (_ termID: String, ScrollbackGate.Release) -> Void
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
        guard let release = gate.output(termID, bytes) else { return }
        deliver(termID, release)
    }

    func reply(_ termID: String, _ bytes: Data) {
        guard let release = gate.scrollback(termID, bytes) else { return }
        deliver(termID, release)
    }

    /// The card is gone; nothing held for it is shown.
    func unmount(_ termID: String) {
        gate.forget(termID)
    }

    func socketLost() {
        for (termID, release) in gate.clearAwaiting() {
            deliver(termID, release)
        }
    }

    private func expire(_ termID: String, _ generation: UInt64) {
        guard let release = gate.expire(termID, generation: generation) else { return }
        deliver(termID, release)
    }
}
