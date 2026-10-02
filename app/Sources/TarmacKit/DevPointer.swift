import CoreGraphics

/// Where a QA-driver press lands and how it gets there (spec 2609.0015, issue
/// #166; parity row Q21).
///
/// The Tauri driver dispatches a DOM event ON an element: where the element is
/// on screen plays no part, and every listener still runs. A native press is
/// hit-tested, so it reaches its target only at a point that is in the window
/// with nothing over it. Where such a point exists the press goes through the
/// window, as a user's does. Where none does it is delivered to the target —
/// the app's own press handling run for that view, then the view's — so a
/// scenario never depends on where the board happens to be scrolled.
public enum DevPointer {
    public enum Delivery: String, Equatable, Sendable {
        /// Through the application's event path, hit test included.
        case window
        /// To the target view, with the app's press handling run for it.
        case target
        /// The app's press handling for the target, and no click at all.
        case handling

        public init(reachable: Bool) {
            self = reachable ? .window : .target
        }
    }

    public struct Candidate: Equatable, Sendable {
        public var point: CGPoint
        /// A press here is hit-tested to the target.
        public var reachable: Bool
        /// A press here would open a link.
        public var onLink: Bool

        public init(point: CGPoint, reachable: Bool, onLink: Bool = false) {
            self.point = point
            self.reachable = reachable
            self.onLink = onLink
        }
    }

    public struct Press: Equatable, Sendable {
        public var point: CGPoint
        public var delivery: Delivery

        public init(point: CGPoint, delivery: Delivery) {
            self.point = point
            self.delivery = delivery
        }
    }

    /// How many cells a press keeps clear of the one before it, on each axis. A
    /// second press inside the double-click interval is a double click, which
    /// selects a word. Measured, the terminal counts one only at the very same
    /// point — it sets no repeat distance — so any other point would do today;
    /// the two cells are margin against it gaining one.
    public static let clearCells: CGFloat = 2

    /// The press on a body whose content is the user's — a doc. A click there
    /// follows a link or presses a button, and the Tauri driver never clicks
    /// inside a document: it dispatches on the wrapper around it. So the card
    /// gets the app's press handling and no click, wherever it is on screen.
    public static func contentPress(in bounds: CGRect) -> Press {
        Press(point: CGPoint(x: bounds.midX, y: bounds.midY), delivery: .handling)
    }

    /// The press on a terminal's body, or on any view whose every point is
    /// safe to click.
    ///
    /// A link is never pressed: a click on one opens it. Among the rest, points
    /// clear of the `last` press come first — they only rank, so a card with
    /// nowhere else to press is still pressed — and among those a reachable
    /// one. With nothing off a link the card gets the press handling alone.
    public static func press(among candidates: [Candidate], last: CGPoint? = nil, cell: CGSize = .zero) -> Press {
        let offLinks = candidates.filter { !$0.onLink }
        let clear = offLinks.filter { candidate in
            guard let last else { return true }
            return abs(candidate.point.x - last.x) >= clearCells * cell.width
                || abs(candidate.point.y - last.y) >= clearCells * cell.height
        }
        let pool = clear.isEmpty ? offLinks : clear
        guard let chosen = pool.first(where: \.reachable) ?? pool.first else {
            return Press(point: candidates.first?.point ?? .zero, delivery: .handling)
        }
        return Press(point: chosen.point, delivery: Delivery(reachable: chosen.reachable))
    }

    /// The press on the bare board. `candidates` are points on the board view
    /// and `cards` every card's frame there. With no bare point on screen the
    /// press is delivered to the board past the cards' far corner: a point no
    /// card covers, so the event says what the press is.
    public static func boardPress(among candidates: [Candidate], cards: [CGRect]) -> Press {
        if let bare = candidates.first(where: \.reachable) { return Press(point: bare.point, delivery: .window) }
        let covered = cards.reduce(CGRect.null) { $0.union($1) }
        let corner = covered.isNull ? CGPoint.zero : CGPoint(x: covered.maxX, y: covered.maxY)
        return Press(point: CGPoint(x: corner.x + margin, y: corner.y + margin), delivery: .target)
    }

    private static let margin: CGFloat = 8
}

/// How a verb's input got in, reported beside the verb's own reply so a run
/// can be audited: whether the app had to be activated to take it, and which
/// way a pointer press was delivered.
public struct DevInjection: Equatable, Sendable {
    public var activated: Bool
    /// Nil for a verb that presses nothing with the pointer.
    public var delivery: DevPointer.Delivery?

    public init(activated: Bool, delivery: DevPointer.Delivery? = nil) {
        self.activated = activated
        self.delivery = delivery
    }

    /// The reply's own fields are never replaced: they are the contract with
    /// the scenario suite, and these ride along.
    public func annotate(_ reply: JSONValue) -> JSONValue {
        guard case .object(var fields) = reply else { return reply }
        var extra: [String: JSONValue] = ["activated": .bool(activated)]
        if let delivery { extra["delivery"] = .string(delivery.rawValue) }
        fields.merge(extra) { own, _ in own }
        return .object(fields)
    }
}
