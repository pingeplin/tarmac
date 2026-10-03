import Foundation
import QuartzCore
import TarmacKit

/// Runs one fly at a time. Each frame it asks the `BoardFly` where the
/// viewport is by the clock, so a slow frame lands in the right place rather
/// than a step behind, and a cancelled fly simply stops being asked — its
/// landing is never reported.
@MainActor
final class ViewportFlight {
    private var timer: Timer?

    func start(
        _ fly: BoardFly,
        onFrame: @escaping @MainActor (BoardViewport) -> Void,
        onLanding: @escaping @MainActor () -> Void
    ) {
        cancel()
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.timer != nil else { return }
                let elapsedMs = (CACurrentMediaTime() - began) * 1000
                onFrame(fly.viewport(atElapsedMs: elapsedMs))
                guard fly.isFinished(atElapsedMs: elapsedMs), self.timer != nil else { return }
                self.cancel()
                onLanding()
            }
        }
        // Common modes: a fly keeps going while a menu or a drag tracks the mouse.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// The run loop holds the timer, so a flight released mid-fly would leave
    /// it firing for good.
    isolated deinit {
        timer?.invalidate()
    }
}
