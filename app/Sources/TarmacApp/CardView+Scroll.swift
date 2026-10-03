import AppKit
import TarmacKit

/// The card's scroll thumb. Where it goes is `ScrollIndicator.frame`'s and
/// when it shows `ScrollIndicator.Visibility`'s; this places it and draws the
/// fade.
extension CardView {
    /// The content said where it is scrolled to, or that it no longer knows.
    func scrollChanged(_ metrics: ScrollMetrics?) {
        scrollMetrics = metrics
        needsLayout = true
    }

    func layoutScrollThumb(body: CGRect) {
        let frame = ScrollIndicator.frame(scrollMetrics, body: body, covered: docBody?.scrollCover ?? 0, scale: scale)
        scrollThumb.isHidden = frame == nil
        if let frame { scrollThumb.frame = frame }
    }

    /// The wheel router gave this card a wheel. The thumb shows where the last
    /// layout put it, and starts to fade once the hold after the last wheel
    /// is over.
    func tookWheel() {
        scrollVisibility.wheeled(atMs: Uptime.nowMs)
        stopScrollFade()
        scrollThumb.alphaValue = 1
        let fade = DispatchWorkItem { [weak self] in self?.fadeScrollThumb() }
        scrollFade = fade
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int(ScrollIndicator.Visibility.holdMs)), execute: fade
        )
    }

    /// The card was deselected: the thumb goes at once.
    func hideScrollThumb() {
        scrollVisibility.reset()
        stopScrollFade()
        scrollThumb.alphaValue = 0
    }

    /// What the dev snapshot says of this card's scroll: a culled card's view
    /// is hidden with everything in it, so nothing of it is laid out.
    var scrollFacts: DevSnapshot.Scroll? {
        scrollMetrics.map {
            DevSnapshot.Scroll(
                metrics: $0, laidOut: !scrollThumb.isHidden && !isHidden,
                alpha: scrollVisibility.alpha(atMs: Uptime.nowMs)
            )
        }
    }

    private func fadeScrollThumb() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TimeInterval(ScrollIndicator.Visibility.fadeMs) / 1000
            scrollThumb.animator().alphaValue = 0
        }
    }

    private func stopScrollFade() {
        scrollFade?.cancel()
        scrollFade = nil
        scrollThumb.layer?.removeAllAnimations()
    }
}
