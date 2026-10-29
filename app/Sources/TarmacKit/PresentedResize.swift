import CoreGraphics

/// The order in which a web view hosted at screen scale takes a new size, so
/// that what shows is always a frame its web process has drawn (#270).
///
/// WebKit applies a web view's new size in its own process and presents the
/// frame for it one to four display frames later. Until then the view shows
/// its old tiles at 1:1: cropped when it shrank, beside a strip of WebKit's
/// default colour where it grew. So the host's bounds, which set the scale the
/// content shows at, move to the new size only once that frame is presented:
/// - Shrink: the page is told its layout first; the bounds and the content's
///   frame wait.
/// - Grow: the bounds go back to the size the content was last fitted under,
///   which stretches the old frame over the card, and the content takes its
///   new frame under them, so the area it gained is clipped; then the layout.
///   The bounds wait.
///
/// Grow or shrink is read from the content's frame, never the bounds: a card
/// resize drags the bounds along with the host's frame before the host sees it.
///
/// Owns no clock and no web view. The host runs a plan's steps and calls
/// `presented` with its generation when WebKit has presented, or once
/// `fallbackMs` has passed; a newer plan makes the older generation stale.
public struct PresentedResize: Sendable {
    /// Well above the 29 ms the slowest presentation took on a heavy page (300
    /// paragraphs and a 600-row table), so the timer does not cut a slow one
    /// short and bring the flash back; a presentation that never comes leaves
    /// the stretched frame up for about as long as a zoom takes to settle.
    public static let fallbackMs = 250

    /// A content frame within this of the target is the same size, moved onto
    /// whole device pixels; WebKit has nothing new to draw for it.
    static let tolerance: CGFloat = 1

    public enum Step: Equatable, Sendable {
        /// The host's bounds take this size.
        case bounds(CGSize)
        /// The content's frame takes this size at the host's origin.
        case contentFrame(CGSize)
        /// The page is told the size it is about to have.
        case layout(CGSize)
        /// The content's frame takes this size, moved onto whole device pixels.
        case fit(CGSize)
    }

    public enum Plan: Equatable, Sendable {
        /// Bounds, layout and frame at once.
        case now
        /// Run these steps, then report the presentation for `generation`.
        case staged(generation: UInt64, steps: [Step])
        /// A staged resize already goes to this size; keep waiting for it.
        case pending
    }

    private var fitted: CGSize?
    private var waiting: (generation: UInt64, target: CGSize)?
    private var lastGeneration: UInt64 = 0

    public init() {}

    /// `content` is the content's frame size now; `deferrable` says the host
    /// can learn of a presentation (it is on screen and the web view offers it).
    public mutating func plan(content: CGSize, target: CGSize, deferrable: Bool) -> Plan {
        guard deferrable, let fitted, content.width > 0, content.height > 0 else { return applyNow(target) }
        if let waiting, Self.same(waiting.target, target) { return .pending }
        guard !Self.same(content, target) else { return applyNow(target) }
        lastGeneration += 1
        waiting = (lastGeneration, target)
        let grows = target.width > content.width + Self.tolerance || target.height > content.height + Self.tolerance
        guard grows else { return .staged(generation: lastGeneration, steps: [.layout(target)]) }
        let reach = CGSize(width: max(content.width, target.width), height: max(content.height, target.height))
        return .staged(generation: lastGeneration, steps: [.bounds(fitted), .contentFrame(reach), .layout(target)])
    }

    /// The steps that were waiting for `generation`'s presentation, or nil when
    /// a newer plan superseded it or they have already run.
    public mutating func presented(_ generation: UInt64) -> [Step]? {
        guard let waiting, waiting.generation == generation else { return nil }
        self.waiting = nil
        fitted = waiting.target
        return [.bounds(waiting.target), .fit(waiting.target)]
    }

    private mutating func applyNow(_ target: CGSize) -> Plan {
        waiting = nil
        fitted = target
        return .now
    }

    private static func same(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}
