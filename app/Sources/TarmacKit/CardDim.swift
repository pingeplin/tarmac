import CoreGraphics

/// How much a card is dimmed. A dead terminal reads as spent; a live terminal
/// that is not the prime one steps back while some terminal on its board is
/// prime. Doc cards are never dimmed.
public enum CardDim {
    public static let deadOpacity: CGFloat = 0.55
    public static let quietOpacity: CGFloat = 0.8

    public static func isQuiet(terminal: Bool, prime: Bool, dead: Bool, boardHasPrime: Bool) -> Bool {
        terminal && boardHasPrime && !prime && !dead
    }

    public static func opacity(dead: Bool, quiet: Bool) -> CGFloat {
        if dead { return deadOpacity }
        return quiet ? quietOpacity : 1
    }
}
