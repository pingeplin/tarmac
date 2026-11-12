import Foundation
import TarmacKit

/// What the main actor knows at a sample: every value of the line but the
/// footprints, which are read off it.
struct SampleGathered: Sendable {
    struct WebView: Sendable {
        let pid: Int32
        let path: String
    }

    var daemonPid: Int32?
    var boardsCount = 0
    var boardsLoaded = 0
    var cardsHTML = 0
    var cardsMarkdown = 0
    var cardsTerminal = 0
    var pending: [SampleLine.Pending] = []
    var webViews: [WebView] = []

    /// Reads each process's footprint once, however many cards share it.
    func sample() -> SampleLine.Sample {
        var footprints: [Int32: UInt64?] = [:]
        let webContent = webViews.map { view in
            let bytes = footprints[view.pid] ?? ProcessFootprint.bytes(of: view.pid)
            footprints[view.pid] = bytes
            return SampleLine.WebContent(pid: view.pid, path: view.path, footprint: bytes)
        }
        return SampleLine.Sample(
            appFootprint: ProcessFootprint.bytes(of: getpid()),
            daemonPid: daemonPid,
            daemonFootprint: daemonPid.flatMap(ProcessFootprint.bytes),
            boardsCount: boardsCount, boardsLoaded: boardsLoaded,
            cardsHTML: cardsHTML, cardsMarkdown: cardsMarkdown, cardsTerminal: cardsTerminal,
            pending: pending, webContent: webContent
        )
    }
}

/// The app's sample log, `tarmac-app.jsonl` (spec 2611.0004): a line at the
/// first restore, one every interval from the start, and a line when an HTML
/// card's pending events go over the limit. Counts and pids are gathered on the main actor;
/// footprints are read and lines appended on one serial queue, so no two
/// appends interleave their size check and their write.
@MainActor
final class SampleLog {
    private let path: String
    private let resource: SampleLine.Resource
    private let gather: @MainActor () -> SampleGathered?
    private var timer: Timer?
    private var wroteBaseline = false

    private static let writes = DispatchQueue(label: "tarmac.sample-log", qos: .utility)

    init(path: String, resource: SampleLine.Resource, gather: @escaping @MainActor () -> SampleGathered?) {
        self.path = path
        self.resource = resource
        self.gather = gather
    }

    func start(intervalSeconds: TimeInterval) {
        stop()
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
    /// has answered and the first board is built. A reconnect sends a restore
    /// again and gets no line.
    func restored() {
        guard !wroteBaseline else { return }
        wroteBaseline = true
        sample()
    }

    func pendingOverLimit(path card: String, count: Int) {
        let line = SampleLine.overLimit(
            path: card, count: count, limit: HTMLCardSession.pendingLimit, resource: resource, atMs: Self.nowMs
        )
        let file = path
        Self.writes.async { SampleLogFile.append(line, to: file) }
    }

    private func sample() {
        guard let gathered = gather() else { return }
        let (file, resource, atMs) = (path, resource, Self.nowMs)
        Self.writes.async {
            SampleLogFile.append(SampleLine.sample(gathered.sample(), resource: resource, atMs: atMs), to: file)
        }
    }

    private static var nowMs: Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}
