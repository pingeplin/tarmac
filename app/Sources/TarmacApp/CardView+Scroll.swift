import AppKit
import TarmacKit

/// The card's scroll thumb. Where it goes is `ScrollIndicator.frame`'s, when
/// it shows `ScrollIndicator.Visibility`'s, and where a drag of it sends the
/// content `ScrollDrag`'s; this places it, draws the fade, and hands the
/// pointer and the offset on.
extension CardView {
    /// The content said where it is scrolled to, or that it no longer knows.
    func scrollChanged(_ metrics: ScrollMetrics?) {
        scrollMetrics = metrics
        needsLayout = true
    }

    func layoutScrollThumb(body: CGRect) {
        scrollTrackBody = body
        let frame = ScrollIndicator.frame(scrollMetrics, body: body, covered: docBody?.scrollCover ?? 0, scale: scale)
        scrollThumb.isHidden = frame == nil
        if let frame { scrollThumb.frame = frame }
        // The thumb moves under a still pointer.
        askWhetherThePointerIsOverTheThumb()
    }

    /// The wheel router gave this card a wheel. The thumb shows where the last
    /// layout put it; a pointer resting there is then over it.
    func tookWheel() {
        updateScrollVisibility { $0.wheeled(atMs: $1) }
        askWhetherThePointerIsOverTheThumb()
    }

    /// The card was deselected: the thumb goes at once, and a drag of it ends.
    func hideScrollThumb() {
        dropScrollDrag()
        updateScrollVisibility { visibility, _ in visibility.reset() }
    }

    var scrollThumbCanBeGrabbed: Bool {
        scrollVisibility.grabbable(atMs: Uptime.nowMs)
    }

    /// The pointer moved: whether it is over this card's thumb.
    func pointerIsOverScrollThumb(_ over: Bool) {
        updateScrollVisibility { $0.pointer(over: over, atMs: $1) }
    }

    // MARK: - Drag

    func thumbPressed(_ event: NSEvent) {
        dropScrollDrag()
        scrollDrag = ScrollDrag(pointerY: thumbPointerY(event), thumb: scrollThumb.frame)
        // The thumb's view is sent no event while it is hidden — the content
        // now fits, a reload, a cull — so the release is read off the
        // application's events, wherever the pointer and the thumb are.
        scrollRelease = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            MainActor.assumeIsolated { self?.endScrollDrag() }
            return event
        }
        updateScrollVisibility { $0.pressed(atMs: $1) }
    }

    func thumbDragged(_ event: NSEvent) {
        guard let offset = scrollDrag?.offset(
            pointerY: thumbPointerY(event), metrics: scrollMetrics, body: scrollTrackBody,
            covered: docBody?.scrollCover ?? 0, scale: scale
        ) else { return }
        if let docBody { docBody.scroll(to: offset) } else { onScrollTo?(offset) }
    }

    /// The release, or what stands in for it when the card goes away under a
    /// held thumb. A drag clamped at the track's end brings no report, so the
    /// pointer is asked for here.
    func endScrollDrag() {
        dropScrollDrag()
        updateScrollVisibility { $0.released(atMs: $1) }
        askWhetherThePointerIsOverTheThumb()
    }

    private func dropScrollDrag() {
        scrollDrag = nil
        if let scrollRelease { NSEvent.removeMonitor(scrollRelease) }
        scrollRelease = nil
    }

    /// The pointer in the coordinates the thumb's frame is in.
    private func thumbPointerY(_ event: NSEvent) -> CGFloat {
        scrollThumb.superview?.convert(event.locationInWindow, from: nil).y ?? 0
    }

    // MARK: - Dev snapshot

    /// What the dev snapshot says of this card's scroll, the thumb's frame in
    /// `view`'s coordinates: a culled card's view is hidden with everything in
    /// it, so nothing of it is laid out.
    func scrollFacts(in view: NSView) -> DevSnapshot.Scroll? {
        scrollMetrics.map {
            DevSnapshot.Scroll(
                metrics: $0, laidOut: !scrollThumb.isHidden && !isHidden,
                alpha: scrollVisibility.alpha(atMs: Uptime.nowMs),
                thumb: scrollThumb.superview.map { view.convert(scrollThumb.frame, from: $0) }
            )
        }
    }

    // MARK: - Visibility

    /// Whether the window's hit test, at the pointer's position, answers this
    /// card's thumb. Only a selected card's thumb can show.
    private func askWhetherThePointerIsOverTheThumb() {
        guard selected, let window, let content = window.contentView else { return }
        pointerIsOverScrollThumb(content.hitTest(window.mouseLocationOutsideOfEventStream) === scrollThumb)
    }

    /// Tells the `Visibility` something, and shows what it then says.
    private func updateScrollVisibility(_ change: (inout ScrollIndicator.Visibility, UInt64) -> Void) {
        let before = scrollVisibility
        let now = Uptime.nowMs
        change(&scrollVisibility, now)
        guard scrollVisibility != before else { return }

        scrollFade?.cancel()
        scrollFade = nil
        scrollThumb.layer?.removeAllAnimations()
        scrollThumb.alphaValue = scrollVisibility.grabbable(atMs: now) ? 1 : 0
        guard let startMs = scrollVisibility.fadeStartsAtMs(atMs: now) else { return }
        let fade = DispatchWorkItem { [weak self] in self?.fadeScrollThumb() }
        scrollFade = fade
        let waitMs = Int(clamping: startMs > now ? startMs - now : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(waitMs), execute: fade)
    }

    private func fadeScrollThumb() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TimeInterval(ScrollIndicator.Visibility.fadeMs) / 1000
            scrollThumb.animator().alphaValue = 0
        }
    }
}
