import Foundation

/// The hand-off between the QA driver's socket thread and the app (spec
/// 2609.0015, #166; parity rows Q6–Q7) — the Swift twin of `DevDriver::dispatch`
/// in `desktop/src-tauri/src/dev_driver.rs` and of the request queue in
/// `desktop/src/devDriver.ts`.
///
/// Three properties make the driver safe to leave unattended:
///   - every wait is BOUNDED, so a scenario can never wedge on an app that is
///     not there (`app_not_ready`) or does not answer (`app_unresponsive`);
///   - each request waits on a slot of its own, so a late answer to one request
///     can never be handed to another;
///   - verbs run ONE AT A TIME, in the order they arrived. A verb the wait gave
///     up on is still running, and the next one does not start until it has
///     finished — otherwise the two would interleave at every suspension point
///     and each reply would describe a state the other was halfway through
///     changing.
public final class DevRelay: @unchecked Sendable {
    public typealias Handler = @Sendable (DevRequest) async -> DevReply

    /// How long the app waits past the verb's own budget. The CLI waits a
    /// second longer still, so an expired wait is reported by whoever observed
    /// it.
    public static let slackMs = 2_000

    private typealias Verb = @Sendable () async -> Void

    private let slackMs: Int
    private let lock = NSLock()
    private var handler: Handler?
    private let verbs: AsyncStream<Verb>.Continuation

    public init(slackMs: Int = DevRelay.slackMs) {
        self.slackMs = slackMs
        let (queued, verbs) = AsyncStream<Verb>.makeStream()
        self.verbs = verbs
        Task {
            for await verb in queued { await verb() }
        }
    }

    deinit {
        verbs.finish()
    }

    /// The app is up and will answer from here on.
    public func attach(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    /// Blocks until the app answers or the bound passes. Called on the socket
    /// thread, one request at a time.
    public func answer(_ request: DevRequest) -> DevReply {
        if case .unknown(let type) = request { return DevRouting.unsupportedVerb(type).reply }
        guard let handler = lock.withLock({ self.handler }) else {
            return DevError(.appNotReady, "the Tarmac window has not attached its dev driver yet").reply
        }
        let slot = Slot()
        verbs.yield { slot.fill(await handler(request)) }
        return slot.wait(ms: Self.waitMs(for: request, slackMs: slackMs))
            ?? DevError(.appUnresponsive, "the dev driver did not answer within its budget").reply
    }

    public static func waitMs(for request: DevRequest, slackMs: Int = DevRelay.slackMs) -> Int {
        (request.timeoutMs ?? 0) + slackMs
    }

    /// One request's answer. An answer after the wait gave up lands here and is
    /// read by nobody.
    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private let filled = DispatchSemaphore(value: 0)
        private var reply: DevReply?

        func fill(_ reply: DevReply) {
            lock.withLock { self.reply = reply }
            filled.signal()
        }

        func wait(ms: Int) -> DevReply? {
            guard filled.wait(timeout: .now() + .milliseconds(ms)) == .success else { return nil }
            return lock.withLock { reply }
        }
    }
}
