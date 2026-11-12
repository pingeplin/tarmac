import Foundation
import TarmacKit

/// The app's sample log, `tarmac-app.jsonl` (spec 2611.0004): a line at the
/// first restore, one every interval from the start, and a line when an HTML
/// card's pending events go over the limit. Counts and pids are gathered on the main actor;
/// footprints are read and lines appended on one serial queue, so no two
/// appends interleave their size check and their write.
@MainActor
final class SampleLog {
    private let file: String
    private let resource: SampleLine.Resource
    private let gather: @MainActor () -> SampleLine.Sample?
    private var timer: Timer?
    private var wroteBaseline = false

    private static let writes = DispatchQueue(label: "tarmac.sample-log", qos: .utility)

    init(file: String, resource: SampleLine.Resource, gather: @escaping @MainActor () -> SampleLine.Sample?) {
        self.file = file
        self.resource = resource
        self.gather = gather
    }

    func start(intervalSeconds: TimeInterval) {
        let timer = Timer(timeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // A sample need not be on the second: let the system batch its wakeup.
        timer.tolerance = intervalSeconds / 10
        // Common modes, so a tracked menu or a live resize cannot hold a sample back.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The first line with the daemon's pid and the boards in it: the daemon
    /// has answered and the active board is restored. A later restore, as
    /// after a reconnect, gets no line.
    func restored() {
        guard !wroteBaseline else { return }
        wroteBaseline = true
        sample()
    }

    func pendingOverLimit(path: String, count: Int) {
        let (file, resource, atMs) = (file, resource, Self.nowMs)
        Self.writes.async {
            let line = SampleLine.overLimit(
                path: path, count: count, limit: HTMLCardSession.pendingLimit, resource: resource, atMs: atMs
            )
            SampleLogFile.append(line, to: file)
        }
    }

    private func sample() {
        guard let unread = gather() else { return }
        let (file, resource, atMs) = (file, resource, Self.nowMs)
        Self.writes.async {
            let sample = unread.reading(appPid: resource.pid, ProcessFootprint.bytes)
            SampleLogFile.append(SampleLine.sample(sample, resource: resource, atMs: atMs), to: file)
        }
    }

    private static var nowMs: Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}
