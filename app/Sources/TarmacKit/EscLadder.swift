/// What ESC does when the board, not the switcher, has it. The rungs are tried
/// in order and the first that applies consumes the key; with none, ESC is not
/// the app's and reaches the focused terminal's program.
public enum EscLadder {
    public struct Facts: Equatable, Sendable {
        public var toastsShowing: Bool
        /// A Return flight left a viewport to go back to.
        public var hasPreFlightViewport: Bool
        /// An HTML card is borrowed.
        public var cardBorrowed: Bool
        /// Some doc card on the active board carries the fresh mark.
        public var hasFreshDoc: Bool
        public var selectedIsDoc: Bool

        public init(
            toastsShowing: Bool = false, hasPreFlightViewport: Bool = false, cardBorrowed: Bool = false,
            hasFreshDoc: Bool = false, selectedIsDoc: Bool = false
        ) {
            self.toastsShowing = toastsShowing
            self.hasPreFlightViewport = hasPreFlightViewport
            self.cardBorrowed = cardBorrowed
            self.hasFreshDoc = hasFreshDoc
            self.selectedIsDoc = selectedIsDoc
        }
    }

    public enum Rung: Equatable, Sendable {
        /// Dismiss every toast.
        case clearToasts
        /// Fly back to the remembered viewport and forget it.
        case flyBack
        /// Give the borrowed card back and focus the prime terminal.
        case unborrow
        /// Take the fresh mark off every doc card on the active board.
        case clearFreshDocs
        /// Deselect the selected doc card.
        case deselectDoc
    }

    public static func rung(_ facts: Facts) -> Rung? {
        if facts.toastsShowing { return .clearToasts }
        if facts.hasPreFlightViewport { return .flyBack }
        if facts.cardBorrowed { return .unborrow }
        if facts.hasFreshDoc { return .clearFreshDocs }
        if EscFocusAction.forFocusedDoc(facts.selectedIsDoc) == .defocus { return .deselectDoc }
        return nil
    }
}
