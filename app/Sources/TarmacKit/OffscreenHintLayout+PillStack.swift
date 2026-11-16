import CoreGraphics

extension OffscreenHintLayout {
    /// A laid-out pill: its edge, arrow glyph, the overlay-local top-left, and
    /// whether it ended up on top of a card.
    public struct PlacedPill: Equatable {
        public var cardID: String
        public var signal: CardSignal
        public var label: String
        public var edge: BoardWayfinding.Edge
        public var arrow: String
        public var left: CGFloat
        public var top: CGFloat
        /// The placed pill still overlaps a card: no free gap of its edge band,
        /// clear of the cards and the chrome, held it, so the view paints it
        /// UNDER the cards (#126). Measured on the rounded rect actually painted, against the raw
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
        /// The view-space rects of the chrome drawn over the pills (the zoom
        /// control, the minimap, each toast). Pills keep clear of them as of a
        /// card, but a pill left under one covers no card, so they never make
        /// a pill `occluded`.
        public var chrome: [CGRect]

        public init(
            edgeInset: CGFloat,
            edgeMargin: CGFloat,
            stackGap: CGFloat,
            pillSize: @escaping (Hint) -> CGSize,
            obstacles: [CGRect] = [],
            chrome: [CGRect] = []
        ) {
            self.edgeInset = edgeInset
            self.edgeMargin = edgeMargin
            self.stackGap = stackGap
            self.pillSize = pillSize
            self.obstacles = obstacles
            self.chrome = chrome
        }
    }

    /// Projects each offscreen hint to an edge, groups by edge, sorts along the
    /// edge, greedily nudges stacked pills apart, clamps inside the view minus the
    /// margins and rounds. Hints whose center is inside the view are skipped.
    ///
    /// An edge is resolved from its start (left, top) forward. When that leaves
    /// a pill under the chrome — the zoom control, the minimap, the toasts — the
    /// edge is resolved again from its end backward, each pill starting where the
    /// forward pass put it, with no side preferred.
    ///
    /// Each edge is placed twice that way: with the band's last gap ending a
    /// pill length short, and with it ending at the band's end.
    /// The short gap keeps a pill off the last free gap, but the full gap can
    /// let an early pill take it and push its siblings off the view. Of the up
    /// to four placings — forward and backward, short and full, in that order —
    /// a later one replaces the best so far only when it leaves fewer pills
    /// covered, by the chrome or by a card, no more pushed past the view's
    /// margins and no more fully off the view. A tie keeps the earlier one.
    public static func stackPills(_ hints: [Hint], in viewRect: CGRect, options: Options) -> [PlacedPill] {
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
            let keepBetter = { (best: Pass, candidate: Pass) in candidate.isBetter(than: best) ? candidate : best }
            let short = placings(group, on: edge, in: viewRect, options: options, lastGapFits: false)
            var best = short.dropFirst().reduce(short[0], keepBetter)
            // With no pill covered, no later placing can be better.
            if best.covered > 0 {
                best = placings(group, on: edge, in: viewRect, options: options, lastGapFits: true).reduce(best, keepBetter)
            }
            placed += best.pills
        }
        return placed
    }

    private struct Projected {
        let hint: Hint
        let placement: BoardWayfinding.HintPlacement
        let size: CGSize
    }

    private struct Pass {
        var pills: [PlacedPill] = []
        /// Pills under the chrome.
        var underChrome = 0
        /// Pills under the chrome or a card.
        var covered = 0
        /// Pills pushed past the view's margins.
        var outside = 0
        /// Pills fully off the view.
        var offView = 0

        func isBetter(than other: Pass) -> Bool {
            covered < other.covered && outside <= other.outside && offView <= other.offView
        }
    }

    /// The forward placing, then the backward one when the forward leaves a
    /// pill under the chrome.
    private static func placings(
        _ group: [Projected], on edge: BoardWayfinding.Edge, in viewRect: CGRect, options: Options, lastGapFits: Bool
    ) -> [Pass] {
        let forward = place(group, on: edge, in: viewRect, options: options, from: nil, lastGapFits: lastGapFits)
        guard forward.underChrome > 0 else { return [forward] }
        return [forward, place(group, on: edge, in: viewRect, options: options, from: forward.pills, lastGapFits: lastGapFits)]
    }

    /// Places one edge's pills, sorted along it. A backward pass — `from` the
    /// forward pass's pills, in the same order, each pill starting where that
    /// put it — works in mirrored coordinates (`x → −x` along the edge), so the
    /// sibling nudge and the overflow run toward the edge's start. A forward
    /// pass on the bottom edge prefers a move to the left.
    private static func place(
        _ group: [Projected], on edge: BoardWayfinding.Edge, in viewRect: CGRect, options: Options,
        from seeds: [PlacedPill]?, lastGapFits: Bool
    ) -> Pass {
        let backward = seeds != nil
        let vertical = edge == .left || edge == .right
        let sign: CGFloat = backward ? -1 : 1
        let preferLower = !backward && edge == .bottom
        let blockers = options.obstacles + options.chrome
        var lastEnd = -CGFloat.infinity
        var pass = Pass()

        for index in backward ? Array(group.indices.reversed()) : Array(group.indices) {
            let item = group[index]
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
            let obstacleIntervals = blockers
                .filter { Placement.rectsIntersect(band, $0) }
                .map { vertical
                    ? Interval(lo: $0.minY - options.stackGap, hi: $0.maxY + options.stackGap)
                    : Interval(lo: $0.minX - options.stackGap, hi: $0.maxX + options.stackGap)
                }
            let desired = seeds.map { vertical ? $0[index].top : $0[index].left }
                ?? BoardWayfinding.clamp(item.placement.along - length / 2, posLo, posHi)
            // A mirrored start: the far end of the span, negated.
            let mirror = { (start: CGFloat) in backward ? -(start + length) : start }
            let resolved = resolveAlongPosition(
                desired: mirror(desired), length: length,
                obstacles: obstacleIntervals.map { backward ? Interval(lo: -$0.hi, hi: -$0.lo) : $0 },
                siblingFloor: lastEnd + options.stackGap,
                posLo: backward ? mirror(posHi) : posLo, posHi: backward ? mirror(posLo) : posHi,
                preferLower: preferLower, lastGapFits: lastGapFits
            )
            lastEnd = resolved + length
            let pos = sign * resolved - (backward ? length : 0)
            let rect = CGRect(
                x: (vertical ? crossPos : pos).roundedHalfUp,
                y: (vertical ? pos : crossPos).roundedHalfUp,
                width: size.width,
                height: size.height
            )
            let occluded = options.obstacles.contains { Placement.rectsIntersect(rect, $0) }
            let underChrome = options.chrome.contains { Placement.rectsIntersect(rect, $0) }
            pass.pills.append(PlacedPill(
                cardID: item.hint.cardID,
                signal: item.hint.signal,
                label: item.hint.label,
                edge: edge,
                arrow: edge.arrow,
                left: rect.minX,
                top: rect.minY,
                occluded: occluded
            ))
            if underChrome { pass.underChrome += 1 }
            if underChrome || occluded { pass.covered += 1 }
            if pos < posLo || pos > posHi { pass.outside += 1 }
            if !Placement.rectsIntersect(rect, viewRect) { pass.offView += 1 }
        }
        if backward { pass.pills.reverse() }
        return pass
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
    /// Otherwise it searches `[max(posLo, siblingFloor), posHi]` for the start in
    /// a free gap (the window minus the obstacle intervals, cards and chrome
    /// alike; with `lastGapFits`, the last gap runs to `posHi + length`, the
    /// band's end, else only to `posHi`) closest to `desired` — at or below it
    /// first, when `preferLower`; ties favor the later gap, matching the sibling
    /// nudge's forward-only bias. If no gap holds the pill, it falls back to the
    /// window-clamped `desired`, on whatever is there. A pill is always
    /// returned, never suppressed.
    private static func resolveAlongPosition(
        desired: CGFloat,
        length: CGFloat,
        obstacles: [Interval],
        siblingFloor: CGFloat,
        posLo: CGFloat,
        posHi: CGFloat,
        preferLower: Bool,
        lastGapFits: Bool
    ) -> CGFloat {
        let lo = max(posLo, siblingFloor)
        if lo > posHi {
            var pos = max(desired, siblingFloor)
            for obstacle in merged(obstacles) where pos < obstacle.hi && pos + length > obstacle.lo {
                pos = obstacle.hi
            }
            return pos
        }

        let end = lastGapFits ? posHi + length : posHi
        let windowed = merged(obstacles)
            .map { Interval(lo: max($0.lo, lo), hi: min($0.hi, end)) }
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
        if end > cursor { gaps.append(Interval(lo: cursor, hi: end)) }

        func nearest(where accept: (CGFloat) -> Bool) -> CGFloat? {
            var best: CGFloat?
            var bestDistance = CGFloat.infinity
            for gap in gaps where gap.hi - gap.lo >= length {
                let candidate = BoardWayfinding.clamp(clampedDesired, gap.lo, gap.hi - length)
                let distance = abs(candidate - clampedDesired)
                if accept(candidate), distance <= bestDistance {
                    bestDistance = distance
                    best = candidate
                }
            }
            return best
        }
        let preferred = preferLower ? nearest { $0 <= clampedDesired } : nil
        return preferred ?? nearest { _ in true } ?? clampedDesired
    }
}
