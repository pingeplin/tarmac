import AppKit
import TarmacKit

/// Samples one key's state every `QuitGuard.pollMs` until stopped.
///
/// It exists because a key's release cannot be waited for: with ⌘ held AppKit
/// does not deliver the other key's keyUp, and a hidden window gets no key
/// events at all. The key sampled is whichever one started the gesture — never
/// a hard-coded Q, so a remapped Quit shortcut is followed too.
@MainActor
final class KeyReleasePoller {
    private var timer: Timer?
    private var keyCode: UInt16 = 0
    private var onSample: (@MainActor (Bool) -> Void)?

    #if DEBUG
    /// `tarmac dev press`'s stand-in for a finger: ORed into the physical read.
    var hold: KeyHold?
    #endif

    func start(keyCode: UInt16, onSample: @escaping @MainActor (_ held: Bool) -> Void) {
        stop()
        self.keyCode = keyCode
        self.onSample = onSample
        let timer = Timer(timeInterval: TimeInterval(QuitGuard.pollMs) / 1_000, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // Common modes, so a tracked menu or a live resize cannot stall it.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Invalidated on the spot, so no sample outlives the phase that asked.
    func stop() {
        timer?.invalidate()
        timer = nil
        onSample = nil
    }

    private func sample() {
        guard let onSample else { return }
        var held = CGEventSource.keyState(.combinedSessionState, key: keyCode)
        #if DEBUG
        held = held || (hold?.holds(keyCode, nowMs: Uptime.nowMs) ?? false)
        #endif
        onSample(held)
    }
}

/// The clock `NSEvent.timestamp` runs on: time since boot, sleep excluded. An
/// event's age is only a plain subtraction against this one.
enum Uptime {
    static var nowMs: UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000
    }
}
