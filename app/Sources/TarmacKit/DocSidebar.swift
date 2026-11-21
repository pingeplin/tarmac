import Foundation

/// The markdown card's sidebar rules (spec 2611.0022, D4–D8), in world px.
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
        case strip
        case docked(Double)
        case overlay(Double)
    }

    public enum Action: Equatable, Sendable {
        case open
        case close
        case resize(Double)
        case reset

        /// The page's `docSidebar` report; nil changes nothing.
        public init?(report: Any) {
            guard let fields = report as? [String: Any], let action = fields["action"] as? String else { return nil }
            switch action {
            case "open": self = .open
            case "close": self = .close
            case "reset": self = .reset
            case "resize":
                guard let raw = fields["width"], case .number(let width)? = JSONValue(foundation: raw),
                      width.isFinite, width > 0 else { return nil }
                self = .resize(width)
            default: return nil
            }
        }
    }

    /// Wide enough to dock the standard sidebar beside the narrowest text.
    static func isWide(cardWidth: Double) -> Bool { cardWidth - standard >= textMinimum }

    /// A narrow card's overlay keeps its grip clear of the card's scroll thumb.
    public static func range(cardWidth: Double) -> ClosedRange<Double> {
        if isWide(cardWidth: cardWidth) { return minimum...min(maximum, cardWidth - textMinimum) }
        let upper = min(maximum, cardWidth - strip - grip - thumbClear)
        return min(minimum, upper)...upper
    }

    public static func resizable(cardWidth: Double) -> Bool {
        let range = range(cardWidth: cardWidth)
        return range.upperBound > range.lowerBound
    }

    /// As for a doc with content: the page shows none for one without.
    public static func mode(cardWidth: Double, stored: Stored, overlayOpen: Bool) -> Mode {
        let range = range(cardWidth: cardWidth)
        let width = min(max(stored.width ?? standard, range.lowerBound), range.upperBound)
        if isWide(cardWidth: cardWidth) { return stored.open ?? true ? .docked(width) : .strip }
        return overlayOpen ? .overlay(width) : .strip
    }

    /// An open overlay is dropped when its card becomes wide, so the card
    /// shows the strip when it is narrow again.
    public static func overlayOpen(_ open: Bool, cardWidth: Double) -> Bool {
        !isWide(cardWidth: cardWidth) && open
    }

    public static func apply(
        _ action: Action, stored: Stored, overlayOpen: Bool, cardWidth: Double
    ) -> (stored: Stored, overlayOpen: Bool) {
        var stored = stored
        var overlayOpen = overlayOpen
        func setOpen(_ open: Bool) {
            if isWide(cardWidth: cardWidth) { stored.open = open } else { overlayOpen = open }
        }
        switch action {
        case .open: setOpen(true)
        case .close: setOpen(false)
        case .resize(let width) where width < minimum: setOpen(false)
        case .resize(let width): stored.width = min(width, maximum)
        case .reset:
            stored.width = standard
            setOpen(true)
        }
        return (stored, overlayOpen)
    }

    /// The state the page lays its sidebar out by (D12).
    public struct PageState: Equatable, Sendable {
        public let mode: String
        public let width: Double
        public let maxWidth: Double
        public let resizable: Bool

        public init(mode: String, width: Double, maxWidth: Double, resizable: Bool) {
            self.mode = mode
            self.width = width
            self.maxWidth = maxWidth
            self.resizable = resizable
        }

        public var arguments: [String: Any] {
            [
                "mode": mode, "width": width, "minWidth": minimum, "maxWidth": maxWidth, "resizable": resizable,
                "strip": strip, "grip": grip, "side": "left",
            ]
        }
    }

    public static func pageState(cardWidth: Double, stored: Stored, overlayOpen: Bool) -> PageState {
        let range = range(cardWidth: cardWidth)
        let mode = mode(cardWidth: cardWidth, stored: stored, overlayOpen: overlayOpen)
        let name: String
        var width = min(max(stored.width ?? standard, range.lowerBound), range.upperBound)
        switch mode {
        case .strip: name = "strip"
        case .docked(let shown):
            name = "docked"
            width = shown
        case .overlay(let shown):
            name = "overlay"
            width = shown
        }
        return PageState(mode: name, width: width, maxWidth: range.upperBound, resizable: resizable(cardWidth: cardWidth))
    }
}
