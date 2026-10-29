import CoreGraphics

/// The order in which a web view hosted at screen scale takes a new size, so
/// that what shows is always a frame its web process has drawn (#270).
///
/// WebKit applies a web view's new size in its own process and presents the
/// frame for it one to four display frames later. Until then the view shows
/// its old tiles at 1:1: cropped when it shrank, beside a strip of WebKit's
/// default colour where it grew. So the host's bounds, which set the scale the
/// content shows at, move to the new size only once that frame is presented.
/// - Shrink: the page is told its layout first; the content's frame waits.
///   On a card resize the bounds have already shrunk with the card, which
///   crops the old frame at its own scale.
/// - Grow: the bounds go back to the size last presented, which stretches the
///   old frame over the card, and the content takes its new frame under them,
///   so the area it gained is clipped; then the layout. A card resize drags
///   the bounds along with the host's frame, so while a resize waits they
///   are put back whenever a new size passes what is presented.
///
/// Grow or shrink is read from the content's frame, never the bounds: a card
/// resize drags the bounds along with the host's frame before the host sees it.
///
/// One resize is in flight at a time. A size asked for while one waits is
/// kept, the latest only, and staged when that one is presented, so a grip
/// drag follows at WebKit's presentation pace instead of superseding the
/// waiting resize at every step and leaving the card stretched throughout.
///
/// Owns no clock and no web view. The host runs a plan's steps and calls
/// `presented` with its generation when WebKit has presented, or once
/// `fallbackMs` has passed; a report for any other generation is ignored.
public struct PresentedResize: Sendable {
    /// Well above the 29 ms the slowest presentation took on a heavy page (300
    /// paragraphs and a 600-row table), so the timer does not cut a slow one
    /// short and bring the flash back; a presentation that never comes leaves
    /// the stretched frame up for about as long as a zoom takes to settle.
    public static let fallbackMs = 250

    /// Sizes this close are the same; a rect taken to the window and back
    /// comes home a few ulps off.
    static let tolerance: CGFloat = 0.01

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
        /// Bounds, layout and frame at once; the layout even when the frame
        /// is already the size, if `relayout`.
        case now(relayout: Bool)
        /// Run these steps, then report the presentation for `generation`.
        case staged(generation: UInt64, steps: [Step])
        /// A staged resize is waiting; this size follows it. Run these steps.
        case pending(steps: [Step])
    }

    /// What a presentation lets the host do: run `steps`, then, when
    /// `awaiting` is set, wait for that generation's presentation.
    public struct Presented: Equatable, Sendable {
        public let steps: [Step]
        public let awaiting: UInt64?
    }

    private var fitted: CGSize?
    /// The resize in flight, and the size of the frame shown while it waits.
    private var waiting: (generation: UInt64, target: CGSize, presented: CGSize)?
    /// The latest size asked for while a resize was waiting.
    private var next: CGSize?
    private var lastGeneration: UInt64 = 0

    public init() {}

    /// `content` is the content's frame size now; `deferrable` says the host
    /// can learn of a presentation (it is on screen and the web view offers it).
    public mutating func plan(content: CGSize, target: CGSize, deferrable: Bool) -> Plan {
        guard deferrable, let fitted, content.width > 0, content.height > 0 else { return applyNow(target) }
        if let waiting {
            next = Self.same(waiting.target, target) ? nil : target
            // The dragged bounds crop what is presented at its own scale; past
            // it they would show what WebKit has not drawn, so they are held.
            return .pending(steps: Self.exceeds(target, waiting.presented) ? [.bounds(fitted)] : [])
        }
        // The content's frame is moved onto whole device pixels, so it is up
        // to a pixel off the size it was fitted to; only `fitted` says that
        // this is no resize. A grip drag's step can be smaller than that pixel.
        guard !Self.same(fitted, target) else { return applyNow(target) }
        let steps = stage(content: content, target: target)
        return .staged(generation: lastGeneration, steps: steps)
    }

    /// The steps that were waiting for `generation`'s presentation, then those
    /// of the size asked for meanwhile, if any, with the generation to report
    /// next; nil when `generation` is not the one waiting.
    public mutating func presented(_ generation: UInt64) -> Presented? {
        guard let waiting, waiting.generation == generation else { return nil }
        self.waiting = nil
        fitted = waiting.target
        guard let target = next else {
            return Presented(steps: [.bounds(waiting.target), .fit(waiting.target)], awaiting: nil)
        }
        next = nil
        // A shrink that follows crops the frame just presented at the card's
        // own scale, as one from rest does; under the presented size's bounds
        // the whole page would show squeezed for a round.
        let bounds = Self.exceeds(target, waiting.target) ? waiting.target : target
        let steps = stage(content: waiting.target, target: target)
        return Presented(steps: [.bounds(bounds), .fit(waiting.target)] + steps, awaiting: lastGeneration)
    }

    private mutating func stage(content: CGSize, target: CGSize) -> [Step] {
        lastGeneration += 1
        guard Self.exceeds(target, content), let fitted else {
            waiting = (lastGeneration, target, content)
            return [.layout(target)]
        }
        let reach = CGSize(width: max(content.width, target.width), height: max(content.height, target.height))
        waiting = (lastGeneration, target, fitted)
        return [.bounds(fitted), .contentFrame(reach), .layout(target)]
    }

    /// `relayout` when the page was last told another size: a shrink tells it
    /// before the frame follows, so the frame alone does not say it is stale.
    private mutating func applyNow(_ target: CGSize) -> Plan {
        let relayout = (waiting?.target ?? fitted).map { !Self.same($0, target) } ?? false
        waiting = nil
        next = nil
        fitted = target
        return .now(relayout: relayout)
    }

    private static func exceeds(_ a: CGSize, _ b: CGSize) -> Bool {
        a.width > b.width + tolerance || a.height > b.height + tolerance
    }

    private static func same(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}
