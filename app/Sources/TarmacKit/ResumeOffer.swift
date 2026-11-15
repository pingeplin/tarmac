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

/// The panel at the foot of a card with an offer (2611.0015 D9): the whole
/// command, and the buttons that decide it.
public enum ResumePanel {
    public enum Choice: Equatable, Sendable { case resume, skip }

    public struct Button: Equatable, Sendable {
        public let choice: Choice
        public let text: String

        public init(choice: Choice, text: String) {
            self.choice = choice
            self.text = text
        }
    }

    public struct Model: Equatable, Sendable {
        public let title: String
        /// `offer.cmd` verbatim, never shortened: `ResumeCommand.check`
        /// passed it, so it is one line with no hidden character.
        public let command: String
        public let buttons: [Button]
    }

    public static func model(offer: ResumeOffer, prime: Bool) -> Model {
        if offer.queued {
            return Model(
                title: "resumes when the shell is ready", command: offer.cmd,
                buttons: [Button(choice: .skip, text: "skip")]
            )
        }
        let keys = offer.armed(prime: prime)
        return Model(
            title: "resume last agent session?", command: offer.cmd,
            buttons: [
                Button(choice: .resume, text: keys ? "⏎ resume" : "resume"),
                Button(choice: .skip, text: keys ? "esc skip" : "skip"),
            ]
        )
    }
}

/// How a resume command reads where space is short: the dead card's strip.
public enum ResumeChip {

    /// `cmd` with each id-like word cut to its first four characters and `…`;
    /// every other character is shown as it is, so a metacharacter is never
    /// hidden. Words are split on single spaces, keeping the spacing.
    public static func display(_ cmd: String) -> String {
        cmd.split(separator: " ", omittingEmptySubsequences: false)
            .map { isIDLike($0) ? "\($0.prefix(4))…" : String($0) }
            .joined(separator: " ")
    }

    /// 13 or more characters, all from `[A-Za-z0-9_-]`, at least one a digit,
    /// and not a flag (RA2).
    private static func isIDLike(_ word: Substring) -> Bool {
        word.count >= 13 && !word.hasPrefix("-") && word.contains(where: \.isASCIIDigit)
            && word.allSatisfy { $0.isASCIIDigit || ($0.isASCII && $0.isLetter) || $0 == "_" || $0 == "-" }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
