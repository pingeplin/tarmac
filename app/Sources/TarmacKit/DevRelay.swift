import Foundation

/// The hand-off between the QA driver's socket thread and the app (spec
/// 2609.0015, #166; parity rows Q6–Q7) — the Swift twin of `DevDriver::dispatch`
/// in `desktop/src-tauri/src/dev_driver.rs`.
///
/// `answer` blocks its caller, and the caller is the one thread that accepts
/// connections, so requests are served strictly one after another and every
/// reply describes the state its own verb produced. Two properties make that
/// safe to leave unattended:
///   - every wait is BOUNDED, so a scenario can never wedge on an app that is
///     not there (`app_not_ready`) or does not answer (`app_unresponsive`);
///   - each request waits on a slot of its own, so a late answer to one request
///     can never be handed to another.
public final class DevRelay: @unchecked Sendable {
    /// Called on the socket thread. The app answers by calling the completion,
    /// once, from any thread.
    public typealias Handler = @Sendable (DevRequest, @escaping @Sendable (DevReply) -> Void) -> Void

    /// How long the app waits past the verb's own budget. The CLI waits a
    /// second longer still, so an expired wait is reported by whoever observed
    /// it.
    public static let slackMs = 2_000

    private let slackMs: Int
    private let lock = NSLock()
    private var handler: Handler?

    public init(slackMs: Int = DevRelay.slackMs) {
        self.slackMs = slackMs
    }

    /// The app is up and will answer from here on.
    public func attach(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    public func answer(_ request: DevRequest) -> DevReply {
        if case .unknown(let type) = request { return DevRouting.unsupportedVerb(type).reply }
        guard let handler = lock.withLock({ self.handler }) else {
            return DevError(.appNotReady, "the Tarmac window has not attached its dev driver yet").reply
        }
        let slot = Slot()
        handler(request) { slot.fill($0) }
        return slot.wait(ms: Self.waitMs(for: request, slackMs: slackMs))
            ?? DevError(.appUnresponsive, "the dev driver did not answer within its budget").reply
    }

    public static func waitMs(for request: DevRequest, slackMs: Int = DevRelay.slackMs) -> Int {
        (request.timeoutMs ?? 0) + slackMs
    }

    /// One request's answer. Filled at most once; an answer after the wait gave
    /// up lands here and is read by nobody.
    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private let filled = DispatchSemaphore(value: 0)
        private var reply: DevReply?

        func fill(_ reply: DevReply) {
            let first = lock.withLock { () -> Bool in
                guard self.reply == nil else { return false }
                self.reply = reply
                return true
            }
            if first { filled.signal() }
        }

        func wait(ms: Int) -> DevReply? {
            guard filled.wait(timeout: .now() + .milliseconds(ms)) == .success else { return nil }
            return lock.withLock { reply }
        }
    }
}
