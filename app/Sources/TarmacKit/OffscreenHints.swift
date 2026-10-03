import CoreGraphics

/// Overlay-level offscreen-hint logic: priority, the single ⏎-fly target, the pill
/// label and the per-edge greedy stacking layout. The edge geometry itself
/// (`BoardWayfinding.hintPlacement`, `Edge.arrow`) lives in `BoardWayfinding`;
/// this adds what lived in the untested AppKit overlay. Pure and time-free — the
/// view supplies the measured pill sizes and the HH:MM text.
public enum OffscreenHintLayout {
    public enum Signal: Equatable, Sendable {
        case bell, live
    }

    /// One signalling offscreen card, in VIEW (overlay-local) coordinates.
    public struct Hint: Equatable, Sendable {
        public var cardID: String
        public var centerView: CGPoint
        public var signal: Signal
        public var label: String
        /// Stacking order; higher is more recently fronted. Feeds `priority`.
        public var z: Int

        public init(cardID: String, centerView: CGPoint, signal: Signal, label: String, z: Int) {
            self.cardID = cardID
            self.centerView = centerView
            self.signal = signal
            self.label = label
            self.z = z
        }
    }

    /// A laid-out pill: its edge, arrow glyph, the overlay-local top-left, and
    /// whether it ended up on top of a card.
    public struct PlacedPill: Equatable {
        public var cardID: String
        public var signal: Signal
        public var label: String
        public var edge: BoardWayfinding.Edge
        public var arrow: String
        public var left: CGFloat
        public var top: CGFloat
        /// The placed pill still overlaps a card: the edge band was saturated and
        /// the gap search had to fall back, so the view paints it UNDER the cards
        /// (#126). Measured on the rounded rect actually painted, against the raw
        /// card rects rather than the stackGap-padded intervals — it means the pill
        /// covers card content, not that it sits close to one.
        public var occluded: Bool
    }

    public struct Options {
        /// Passed to `BoardWayfinding.hintPlacement` as the edge inset.
        public var edgeInset: CGFloat
        /// Gap kept between a pill and the viewport edge.
        public var edgeMargin: CGFloat
        /// Minimum gap between two stacked pills on the same edge.
        public var stackGap: CGFloat
        /// Measured pill size (the view knows the text metrics).
        public var pillSize: (Hint) -> CGSize
        /// Every currently-visible card's view-space rect, a uniform obstacle set
        /// (no card identity) that pills are nudged clear of.
        public var obstacles: [CGRect]

        public init(
            edgeInset: CGFloat,
            edgeMargin: CGFloat,
            stackGap: CGFloat,
            pillSize: @escaping (Hint) -> CGSize,
            obstacles: [CGRect] = []
        ) {
            self.edgeInset = edgeInset
            self.edgeMargin = edgeMargin
            self.stackGap = stackGap
            self.pillSize = pillSize
            self.obstacles = obstacles
        }
    }

    /// A bell always outranks live; within a class the most-recently-fronted
    /// (higher z) wins. Saturates rather than overflowing for a huge `z`.
    public static func priority(signal: Signal, z: Int) -> Int {
        let (sum, overflowed) = (signal == .bell ? 1000 : 0).addingReportingOverflow(z)
        return overflowed ? .max : sum
    }

    /// The single ⏎-fly target: the highest-priority hint's card id, or nil when
    /// empty. The first wins a tie (strictly-greater swap), so callers must
    /// iterate cards in a stable order for determinism.
    public static func flyTarget(_ hints: [Hint]) -> String? {
        var best: Hint?
        var bestPriority = Int.min
        for hint in hints {
            let candidate = priority(signal: hint.signal, z: hint.z)
            if best == nil || candidate > bestPriority {
                best = hint
                bestPriority = candidate
            }
        }
        return best?.cardID
    }

    /// A bell reads `name · hhmm` (middle dot U+00B7); live reads just the name.
    public static func pillLabel(signal: Signal, name: String, hhmm: String) -> String {
        signal == .bell ? "\(name) · \(hhmm)" : name
    }

    /// Projects each offscreen hint to an edge, groups by edge, sorts along the
    /// edge, greedily nudges stacked pills apart, clamps inside the view minus the
    /// margins and rounds. Hints whose center is inside the view are skipped.
    public static func stackPills(_ hints: [Hint], in viewRect: CGRect, options: Options) -> [PlacedPill] {
        struct Projected {
            let hint: Hint
            let placement: BoardWayfinding.HintPlacement
            let size: CGSize
        }
        let projected = hints.compactMap { hint -> Projected? in
            guard let placement = BoardWayfinding.hintPlacement(
                cardCenterView: hint.centerView, viewRect: viewRect, inset: options.edgeInset
            ) else { return nil }
            return Projected(hint: hint, placement: placement, size: options.pillSize(hint))
        }

        var placed: [PlacedPill] = []
        for edge in [BoardWayfinding.Edge.left, .right, .top, .bottom] {
            let group = projected
                .filter { $0.placement.edge == edge }
                .enumerated()
                .sorted { ($0.element.placement.along, $0.offset) < ($1.element.placement.along, $1.offset) }
                .map(\.element)
            let vertical = edge == .left || edge == .right
            var lastEnd = -CGFloat.infinity

            for item in group {
                let size = item.size
                let length = vertical ? size.height : size.width
                let posLo = (vertical ? viewRect.minY : viewRect.minX) + options.edgeMargin
                let posHi = (vertical ? viewRect.maxY : viewRect.maxX) - length - options.edgeMargin
                let crossPos: CGFloat
                switch edge {
                case .left: crossPos = viewRect.minX + options.edgeMargin
                case .right: crossPos = viewRect.maxX - size.width - options.edgeMargin
                case .top: crossPos = viewRect.minY + options.edgeMargin
                case .bottom: crossPos = viewRect.maxY - size.height - options.edgeMargin
                }
                let band = vertical
                    ? CGRect(x: crossPos, y: viewRect.minY, width: size.width, height: viewRect.height)
                    : CGRect(x: viewRect.minX, y: crossPos, width: viewRect.width, height: size.height)
                let obstacleIntervals = options.obstacles
                    .filter { Placement.rectsIntersect(band, $0) }
                    .map { vertical
                        ? Interval(lo: $0.minY - options.stackGap, hi: $0.maxY + options.stackGap)
                        : Interval(lo: $0.minX - options.stackGap, hi: $0.maxX + options.stackGap)
                    }
                let desired = BoardWayfinding.clamp(item.placement.along - length / 2, posLo, posHi)
                let pos = resolveAlongPosition(
                    desired: desired, length: length, obstacles: obstacleIntervals,
                    siblingFloor: lastEnd + options.stackGap, posLo: posLo, posHi: posHi
                )
                lastEnd = pos + length
                let rect = CGRect(
                    x: (vertical ? crossPos : pos).roundedHalfUp,
                    y: (vertical ? pos : crossPos).roundedHalfUp,
                    width: size.width,
                    height: size.height
                )
                placed.append(PlacedPill(
                    cardID: item.hint.cardID,
                    signal: item.hint.signal,
                    label: item.hint.label,
                    edge: edge,
                    arrow: edge.arrow,
                    left: rect.minX,
                    top: rect.minY,
                    occluded: options.obstacles.contains { Placement.rectsIntersect(rect, $0) }
                ))
            }
        }
        return placed
    }

    private struct Interval {
        var lo: CGFloat
        var hi: CGFloat
    }

    private static func merged(_ intervals: [Interval]) -> [Interval] {
        var out: [Interval] = []
        for interval in intervals.sorted(by: { $0.lo < $1.lo }) {
            if let last = out.last, interval.lo <= last.hi {
                out[out.count - 1].hi = max(last.hi, interval.hi)
            } else {
                out.append(interval)
            }
        }
        return out
    }

    /// Finds a position for a `length`-long pill that never overlaps the previous
    /// sibling on this edge (`siblingFloor`) and, best-effort, avoids `obstacles`
    /// too — while always staying inside `[posLo, posHi]`, since the overlay clips
    /// at the viewport edge: an unclamped pill would simply vanish, which is worse
    /// than residual overlap.
    ///
    /// The one exception is pure over-saturation — so many same-edge pills that
    /// `siblingFloor` alone has already pushed past `posHi`. That has no valid
    /// answer in-bounds, so it pushes forward past whatever is in the way and lets
    /// the pill overflow.
    ///
    /// Otherwise it searches `[max(posLo, siblingFloor), posHi]` for the free gap
    /// (the window minus the obstacle intervals) closest to `desired`; ties favor
    /// the later gap, matching the sibling nudge's forward-only bias. If obstacles
    /// saturate the whole window, it falls back to the window-clamped `desired`.
    /// A pill is always returned, never suppressed.
    private static func resolveAlongPosition(
        desired: CGFloat,
        length: CGFloat,
        obstacles: [Interval],
        siblingFloor: CGFloat,
        posLo: CGFloat,
        posHi: CGFloat
    ) -> CGFloat {
        let lo = max(posLo, siblingFloor)
        if lo > posHi {
            var pos = max(desired, siblingFloor)
            for obstacle in merged(obstacles) where pos < obstacle.hi && pos + length > obstacle.lo {
                pos = obstacle.hi
            }
            return pos
        }

        let windowed = merged(obstacles)
            .map { Interval(lo: max($0.lo, lo), hi: min($0.hi, posHi)) }
            .filter { $0.hi > $0.lo }
        let clampedDesired = BoardWayfinding.clamp(desired, lo, posHi)
        if !windowed.contains(where: { clampedDesired < $0.hi && clampedDesired + length > $0.lo }) {
            return clampedDesired
        }

        var gaps: [Interval] = []
        var cursor = lo
        for obstacle in windowed {
            if obstacle.lo > cursor { gaps.append(Interval(lo: cursor, hi: obstacle.lo)) }
            cursor = max(cursor, obstacle.hi)
        }
        if posHi > cursor { gaps.append(Interval(lo: cursor, hi: posHi)) }

        var best: CGFloat?
        var bestDistance = CGFloat.infinity
        for gap in gaps where gap.hi - gap.lo >= length {
            let candidate = BoardWayfinding.clamp(clampedDesired, gap.lo, gap.hi - length)
            let distance = abs(candidate - clampedDesired)
            if distance <= bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best ?? clampedDesired
    }
}
