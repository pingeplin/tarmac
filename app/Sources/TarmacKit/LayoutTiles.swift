import CoreGraphics

/// The board ↔ layout-tile codec: turns the live card set into the wire
/// `LayoutTile`s the `layout` message persists, and parses a restored `tiles`
/// list back into the term / doc placements the board rebuilds from. A term tile
/// carries its `term_id` and geometry; a board doc tile carries its path,
/// geometry and `loose` (= not attached). A tile with all-nil geometry is an M1
/// tile, placed by the caller's scatter.
///
/// Incoming `shelf: true` tiles — saved before the shelf was removed — are
/// dropped silently, and `build` never emits one.
public enum LayoutTiles {
    /// A live terminal card, ready to persist.
    public struct TermInput: Equatable, Sendable {
        public var termID: String
        public var frame: CGRect
        public var z: Double
        /// Exited and hold-open placeholders are never persisted.
        public var dead: Bool

        public init(termID: String, frame: CGRect, z: Double, dead: Bool) {
            self.termID = termID
            self.frame = frame
            self.z = z
            self.dead = dead
        }
    }

    /// A live doc card on the board; `attached` true means still gravity-bound.
    public struct DocInput: Equatable, Sendable {
        public var path: String
        public var frame: CGRect
        public var z: Double
        public var attached: Bool

        public init(path: String, frame: CGRect, z: Double, attached: Bool) {
            self.path = path
            self.frame = frame
            self.z = z
            self.attached = attached
        }
    }

    /// A terminal placement parsed from a restored tile. `frame` is nil for an M1
    /// geometry-less tile; `termID` is nil for a legacy single-terminal tile.
    public struct ParsedTerm: Equatable, Sendable {
        public var termID: String?
        public var frame: CGRect?
        public var z: Int

        public init(termID: String?, frame: CGRect?, z: Int) {
            self.termID = termID
            self.frame = frame
            self.z = z
        }
    }

    /// A board doc placement parsed from a restored tile; a nil `frame` means M1.
    public struct ParsedDoc: Equatable, Sendable {
        public var path: String
        public var frame: CGRect?
        public var z: Int
        public var attached: Bool

        public init(path: String, frame: CGRect?, z: Int, attached: Bool) {
            self.path = path
            self.frame = frame
            self.z = z
            self.attached = attached
        }
    }

    public struct Parsed: Equatable, Sendable {
        public var terms: [ParsedTerm]
        public var docs: [ParsedDoc]

        public init(terms: [ParsedTerm], docs: [ParsedDoc]) {
            self.terms = terms
            self.docs = docs
        }
    }

    private static let zLimit = 2_000_000_000.0

    /// Surviving terminals first (dead ones excluded), then board docs sorted by
    /// path — by UTF-16 code unit, the order the persisted state was written in —
    /// for a deterministic list.
    public static func build(terms: [TermInput], docs: [DocInput]) -> [LayoutTile] {
        let termTiles = terms.filter { !$0.dead }.map { term in
            LayoutTile(
                kind: "term",
                x: Double(term.frame.origin.x), y: Double(term.frame.origin.y),
                w: Double(term.frame.size.width), h: Double(term.frame.size.height),
                z: wireZ(term.z),
                termID: term.termID
            )
        }
        let docTiles = docs
            .sorted { $0.path.utf16.lexicographicallyPrecedes($1.path.utf16) }
            .map { doc in
                LayoutTile(
                    kind: "doc",
                    path: doc.path,
                    x: Double(doc.frame.origin.x), y: Double(doc.frame.origin.y),
                    w: Double(doc.frame.size.width), h: Double(doc.frame.size.height),
                    z: wireZ(doc.z),
                    loose: !doc.attached
                )
            }
        return termTiles + docTiles
    }

    /// Splits a restored tile list into term and board-doc placements. Unknown
    /// kinds are skipped (receiver rule), as are doc tiles without a path
    /// (unplaceable) and legacy shelf tiles. `z` defaults to 0 and a doc is
    /// attached unless its tile says `loose`.
    public static func parse(_ tiles: [LayoutTile]) -> Parsed {
        var terms: [ParsedTerm] = []
        var docs: [ParsedDoc] = []
        for tile in tiles {
            switch tile.kind {
            case "term":
                terms.append(ParsedTerm(termID: tile.termID, frame: frame(of: tile), z: tile.z ?? 0))
            case "doc":
                guard let path = tile.path, tile.shelf != true else { continue }
                docs.append(ParsedDoc(path: path, frame: frame(of: tile), z: tile.z ?? 0, attached: tile.loose != true))
            default:
                continue
            }
        }
        return Parsed(terms: terms, docs: docs)
    }

    private static func frame(of tile: LayoutTile) -> CGRect? {
        guard let x = tile.x, let y = tile.y, let w = tile.w, let h = tile.h else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Stacking order is a small index, but it is clamped to a safe range before it
    /// becomes the wire's `i64`, so a corrupt or huge `z` can never silently
    /// truncate — or trap the integer conversion. NaN has no order; it persists as 0.
    private static func wireZ(_ z: Double) -> Int {
        guard !z.isNaN else { return 0 }
        return Int(min(max(z.roundedHalfUp, -zLimit), zLimit))
    }
}
