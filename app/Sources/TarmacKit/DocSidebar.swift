import Foundation

/// The markdown card's sidebar rules (spec 2611.0022, D4–D8a), in world px.
public enum DocSidebar {
    public static let standard = 240.0
    public static let minimum = 160.0
    public static let maximum = 420.0
    public static let strip = 30.0
    public static let grip = 8.0
    public static let textMinimum = Double(Placement.docSize.width)
    public static let thumbClear = Double(ScrollIndicator.width + ScrollIndicator.inset)

    /// The card's choice; nil is no choice yet.
    public struct Stored: Equatable, Sendable {
        public var width: Double?
        public var open: Bool?

        public init(width: Double? = nil, open: Bool? = nil) {
            self.width = width
            self.open = open
        }
    }

    public enum Mode: Equatable, Sendable {
        case none
        case strip
        case docked(Double)
        case overlay(Double)
    }

    public enum Action: Equatable, Sendable {
        case open
        case close
        case resize(Double)
        case reset

        public init?(report: Any) {
            self = .reset
        }
    }

    public static func range(cardWidth: Double) -> ClosedRange<Double> { 0...0 }

    public static func resizable(cardWidth: Double) -> Bool { false }

    public static func mode(cardWidth: Double, hasContent: Bool, stored: Stored, overlayOpen: Bool) -> Mode {
        .docked(0)
    }

    public static func overlayOpen(_ open: Bool, cardWidth: Double) -> Bool { !open }

    public static func apply(
        _ action: Action, stored: Stored, overlayOpen: Bool, cardWidth: Double
    ) -> (stored: Stored, overlayOpen: Bool) {
        (Stored(width: -1, open: nil), !overlayOpen)
    }

    public static func outlineCount(result: Any?) -> Int? { -1 }

    public static func hasContent(fieldCount: Int, outlineCount: Int) -> Bool { fieldCount < 0 }
}
