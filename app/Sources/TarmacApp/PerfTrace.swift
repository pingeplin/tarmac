import Foundation
import QuartzCore
import os

/// Removable perf instrumentation for the whiteboard hot paths (branch
/// `perf/whiteboard-profiling`). Two channels, both fed from the same call site:
///
/// 1. **os_signpost intervals / events** — always compiled in, but near-free
///    unless an Instruments trace is recording. Record a "Logging" / custom
///    instrument against subsystem `dev.tarmac.perf`, category `whiteboard`, to
///    see `draw` / `reproject` / `edges` / `persist` intervals (and the
///    `gridDots` / `visibleCards` gauges) on a timeline.
/// 2. **A stderr aggregator** — gated behind `TARMAC_PERF=1` in the environment
///    (zero arithmetic when unset; only the two signpost calls run). Accumulates
///    per-key durations + gauges and prints a rolling summary
///    (n / mean / p95 / max) at most every `flushInterval` seconds, so a
///    baseline reads straight off the console without attaching Instruments.
///
/// Capture a baseline by launching with `TARMAC_PERF=1`, panning the board at
/// zoom 1.0, then 0.49, then 0.28, and reading the `draw` / `gridDots` lines.
/// Remove this file and its call sites before the branch merges — see the
/// instrumentation plan in docs/perf-whiteboard-zoom.md.
@MainActor
enum PerfTrace {
    /// Console-aggregator gate. Signposts stay live regardless (they cost almost
    /// nothing when no tool is recording); only the stderr summary keys off this.
    /// The benchmark (`TARMAC_PERF_BENCH=1`) implies the console channel.
    static let consoleEnabled =
        ProcessInfo.processInfo.environment["TARMAC_PERF"] == "1"
        || ProcessInfo.processInfo.environment["TARMAC_PERF_BENCH"] == "1"

    /// When set, AppController runs the scripted zoom-sweep benchmark after
    /// launch instead of waiting for live pan/zoom (see `runPerfBenchmarkIfRequested`).
    static let benchmarkRequested = ProcessInfo.processInfo.environment["TARMAC_PERF_BENCH"] == "1"

    private static let log = OSLog(subsystem: "dev.tarmac.perf", category: "whiteboard")

    /// Times `body`, emitting a signpost interval named `name` and (when the
    /// console channel is on) feeding its duration to the aggregator under the
    /// same key. Nested calls nest cleanly in Instruments; in the console
    /// summary an inner span's time is a SUBSET of its outer span's (e.g.
    /// `edges` ⊂ `reproject`), so read them as a breakdown, not a sum.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () -> T) -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        guard consoleEnabled else {
            defer { os_signpost(.end, log: log, name: name, signpostID: id) }
            return body()
        }
        let t0 = CACurrentMediaTime()
        let result = body()
        let dt = CACurrentMediaTime() - t0
        os_signpost(.end, log: log, name: name, signpostID: id)
        Aggregator.shared.record(key: String(describing: name), seconds: dt)
        return result
    }

    /// Records a point value (a count / size, not a duration) under `name`. The
    /// value is `@autoclosure`d and only evaluated when the console channel is on,
    /// so a gauge whose argument is a per-frame reduce over all cards costs nothing
    /// when profiling is off.
    static func gauge(_ name: StaticString, _ value: @autoclosure () -> Int) {
        guard consoleEnabled else { return }
        let v = value()
        os_signpost(.event, log: log, name: name, "%{public}ld", v)
        Aggregator.shared.record(key: String(describing: name), value: Double(v))
    }

    /// Synchronously prints the aggregator's current accumulation under `label`
    /// and clears it, bypassing the timed-flush cadence — the benchmark uses this
    /// to emit one clean line per zoom level. No-op when the console channel is off.
    static func flush(_ label: String) {
        guard consoleEnabled else { return }
        Aggregator.shared.drain(label: label)
    }
}

/// Rolling accumulator behind `TARMAC_PERF=1`. Single-threaded by construction
/// (every whiteboard hot path is main-thread), so it needs no locking.
@MainActor
private final class Aggregator {
    static let shared = Aggregator()

    private var durations: [String: [Double]] = [:]
    private var gauges: [String: [Double]] = [:]
    private var lastFlush = CACurrentMediaTime()
    private let flushInterval: Double = 1.5

    func record(key: String, seconds: Double) {
        durations[key, default: []].append(seconds)
        maybeFlush()
    }

    func record(key: String, value: Double) {
        gauges[key, default: []].append(value)
        maybeFlush()
    }

    private func maybeFlush() {
        // During the scripted benchmark only the per-level `drain` prints, so a
        // slow level (40–130ms/frame) isn't split into unlabeled timed flushes.
        guard !PerfTrace.benchmarkRequested else { return }
        let now = CACurrentMediaTime()
        guard now - lastFlush >= flushInterval else { return }
        lastFlush = now
        flush(label: nil)
        durations.removeAll(keepingCapacity: true)
        gauges.removeAll(keepingCapacity: true)
    }

    /// Prints the current accumulation under `label`, clears it, and resets the
    /// flush clock — the synchronous entry point used by `PerfTrace.flush`.
    func drain(label: String) {
        flush(label: label)
        durations.removeAll(keepingCapacity: true)
        gauges.removeAll(keepingCapacity: true)
        lastFlush = CACurrentMediaTime()
    }

    private func flush(label: String?) {
        var parts: [String] = []
        for key in durations.keys.sorted() {
            let s = Self.stats(durations[key]!)
            parts.append("\(key) n=\(s.n) mean=\(Self.ms(s.mean)) p95=\(Self.ms(s.p95)) max=\(Self.ms(s.max))")
        }
        for key in gauges.keys.sorted() {
            let s = Self.stats(gauges[key]!)
            parts.append("\(key) mean=\(Int(s.mean.rounded())) max=\(Int(s.max.rounded()))")
        }
        guard !parts.isEmpty else { return }
        let prefix = label.map { "⟦perf⟧ \($0)  " } ?? "⟦perf⟧ "
        FileHandle.standardError.write(Data((prefix + parts.joined(separator: "  ·  ") + "\n").utf8))
    }

    private static func stats(_ xs: [Double]) -> (n: Int, mean: Double, p95: Double, max: Double) {
        let sorted = xs.sorted()
        let n = sorted.count
        let mean = sorted.reduce(0, +) / Double(n)
        let p95 = sorted[min(n - 1, Int(0.95 * Double(n)))]
        return (n, mean, p95, sorted[n - 1])
    }

    /// Seconds → a compact millisecond string (e.g. `4.2ms`).
    private static func ms(_ seconds: Double) -> String {
        String(format: "%.2fms", seconds * 1000)
    }
}
