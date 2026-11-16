import Foundation

/// A cold-spawned terminal's offer to run the command its record kept
/// (spec 2611.0011; 2611.0015 D1–D4): a panel until the user decides by a
/// key or a click. A value; the wiring stores what `step` returns and
/// performs its effect.
public struct ResumeOffer: Equatable, Sendable {
    public let cmd: String
    /// False until the card's first output: before it, no key runs the command.
    public private(set) var shellUp: Bool
    /// A request came before the shell was up: the command runs at the first
    /// output (2611.0015 D1).
    public private(set) var queued: Bool

    /// Nil for no command, or one `ResumeCommand.check` refuses.
    public static func make(cmd: String?) -> ResumeOffer? {
        ResumeCommand.accepted(cmd).map { ResumeOffer(cmd: $0, shellUp: false, queued: false) }
    }

    /// A queued offer is never armed: it runs at the output that would arm it.
    public func armed(prime: Bool) -> Bool { shellUp && prime }

    public enum Event: Equatable, Sendable {
        /// A chunk released to the card.
        case output(byteCount: Int)
        /// Any `.user` bytes about to go to the PTY.
        case userInput
        /// The `.runResume` rung fired for this card.
        case returnKey(prime: Bool)
        /// `resume all` on the restore card, or a click on the panel's
        /// `resume`: on any card, prime or not.
        case request
        /// `skip all` on the restore card, or a click on the panel's `skip`.
        case skip
    }

    public enum Effect: Equatable, Sendable {
        /// The command's UTF-8 and one carriage return, sent as typed input.
        case run(Data)
        /// Ask the daemon to drop the record (2611.0015 D4): a click sends no
        /// byte, so the typed-input drop never sees it.
        case skip
    }

    /// Any user byte drops the offer, in every state (D9): bytes typed before
    /// the prompt would otherwise be prefixed to the command. A nil offer
    /// stays nil, so the command runs at most once.
    public static func step(_ offer: ResumeOffer?, _ event: Event) -> (offer: ResumeOffer?, effect: Effect?) {
        guard var offer else { return (nil, nil) }
        switch event {
        case .output(let byteCount):
            guard byteCount > 0 else { return (offer, nil) }
            if offer.queued { return (nil, offer.run) }
            offer.shellUp = true
            return (offer, nil)
        case .userInput:
            return (nil, nil)
        case .returnKey(let prime):
            guard offer.armed(prime: prime) else { return (offer, nil) }
            return (nil, offer.run)
        case .request:
            if offer.shellUp { return (nil, offer.run) }
            offer.queued = true
            return (offer, nil)
        case .skip:
            return (nil, .skip)
        }
    }

    private var run: Effect { .run(Data(cmd.utf8) + Data([0x0D])) }
}
