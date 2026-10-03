import Foundation

/// `tarmac dev snapshot [--until <expr>] [--timeout <ms>]` (spec 2609.0015,
/// #166): when the wait answers, and with what. The app owns the clock and the
/// snapshot; this is one turn of its loop, so the loop itself never blocks.
///
/// The check comes before the deadline on every turn: `--timeout 0` evaluates
/// once, and an expression that holds on the last look still answers ok.
public struct DevSnapshotWait: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case reply(DevReply)
        /// Re-read the snapshot `pollMs` from now and step again.
        case pollAgain
    }

    /// A timer, not a frame callback: every fact a wait is for (a grid refit,
    /// the daemon's 750 ms `term_proc` poll, a debounced persist) is slower than
    /// a frame.
    public static let pollMs = 50
    /// What the CLI sends when no `--timeout` is given.
    public static let defaultTimeoutMs = 5_000

    private let source: String?
    private let expression: DevUntil.Expression?
    private let timeoutMs: Int

    /// Throws `bad_expr` for a malformed expression, at once: one that can
    /// never hold must not spend the budget pretending it might.
    public init(until source: String?, timeoutMs: Int?) throws {
        self.source = source
        self.timeoutMs = timeoutMs ?? Self.defaultTimeoutMs
        do {
            expression = try source.map(DevUntil.parse)
        } catch let error as DevUntil.ParseError {
            throw DevError.badExpression(error, source: source ?? "")
        }
    }

    public func step(snapshot: JSONValue, elapsedMs: Int) -> Step {
        guard let expression, let source, !DevUntil.evaluate(expression, against: snapshot) else {
            return .reply(DevReply(ok: true, body: snapshot.jsonString))
        }
        guard elapsedMs >= timeoutMs else { return .pollAgain }
        return .reply(DevError.timeout(expression: source, timeoutMs: timeoutMs, snapshot: snapshot).reply)
    }
}
