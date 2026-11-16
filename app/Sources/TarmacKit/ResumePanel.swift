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
