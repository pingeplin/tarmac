import Foundation

/// A cold-spawned terminal's offer to run the command its record kept
/// (spec 2611.0011): `↻ last here: <cmd>` until the user's first key decides.
/// A value; the wiring stores what `step` returns and performs its effect.
public struct ResumeOffer: Equatable, Sendable {
    public let cmd: String
    /// False until the card's first output: before it, no key runs the command.
    public private(set) var shellUp: Bool

    /// Nil for no command, or one `ResumeCommand.check` refuses.
    public static func make(cmd: String?) -> ResumeOffer? {
        guard let cmd, ResumeCommand.check(cmd) == nil else { return nil }
        return ResumeOffer(cmd: cmd, shellUp: false)
    }

    public func armed(prime: Bool) -> Bool { shellUp && prime }

    public enum Event: Equatable, Sendable {
        /// A chunk released to the card.
        case output(byteCount: Int)
        /// Any `.user` bytes about to go to the PTY.
        case userInput
        /// The `.runResume` rung fired for this card.
        case returnKey(prime: Bool)
    }

    public enum Effect: Equatable, Sendable {
        /// The command's UTF-8 and one carriage return, sent as typed input.
        case run(Data)
    }

    /// Any user byte drops the offer, in every state (D9): bytes typed before
    /// the prompt would otherwise be prefixed to the command. A nil offer
    /// stays nil, so the command runs at most once.
    public static func step(_ offer: ResumeOffer?, _ event: Event) -> (offer: ResumeOffer?, effect: Effect?) {
        guard var offer else { return (nil, nil) }
        switch event {
        case .output(let byteCount):
            if byteCount > 0 { offer.shellUp = true }
            return (offer, nil)
        case .userInput:
            return (nil, nil)
        case .returnKey(let prime):
            guard offer.armed(prime: prime) else { return (offer, nil) }
            return (nil, .run(Data(offer.cmd.utf8) + Data([0x0D])))
        }
    }
}

/// What the resume chip shows.
public enum ResumeChip {
    public struct Model: Equatable, Sendable {
        public let text: String
        /// The whole command, verbatim.
        public let toolTip: String
    }

    public static func model(offer: ResumeOffer, prime: Bool) -> Model {
        let hint = offer.armed(prime: prime) ? "  ⏎ run · esc skip" : ""
        return Model(text: "↻ last here: \(display(offer.cmd))\(hint)", toolTip: offer.cmd)
    }

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
