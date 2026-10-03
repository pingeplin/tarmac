import AppKit
import TarmacKit

/// Keeps a web view at its on-screen size inside a card the board scales.
///
/// The board zooms a card by giving it a frame that differs from its bounds,
/// which stretches the bitmap of everything in it. A web view's tiles are
/// drawn in another process at the size of its own bounds, so stretched they
/// blur. This view undoes the card's scale for its one subview: its bounds are
/// its frame times the zoom, and the web view fills them, laid out and
/// rasterised at real screen points. The page inside carries the zoom itself.
///
/// While the zoom is changing the bounds are left alone, so the card's stretch
/// shows for those frames; once it has held still they take the new size.
@MainActor
final class ScreenSpaceHost: NSView {
    /// The zoom the content is sized for.
    private(set) var settledZoom: CGFloat = 1
    /// The board's zoom as last reported, settled or not.
    private(set) var zoom: CGFloat = 1

    /// Fires just before the content takes a new size, with that size in
    /// points, so a page can be told its layout ahead of its viewport.
    var onResize: ((CGSize) -> Void)?

    private let content: NSView
    private var settle: DispatchWorkItem?
    private var knowsZoom = false
    private var backing = BackingScaleWatch()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The first zoom, and any zoom while the card is off screen, applies at
    /// once; after that a change waits until the zoom has held still.
    func setBoardZoom(_ zoom: CGFloat) {
        guard zoom.isFinite, zoom > 0, zoom != self.zoom || !knowsZoom else { return }
        self.zoom = zoom
        settle?.cancel()
        guard knowsZoom, window != nil, !isHiddenOrHasHiddenAncestor else {
            knowsZoom = true
            applyZoom()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.applyZoom() }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CardZoom.settleDelay, execute: work)
    }

    private func applyZoom() {
        settle = nil
        settledZoom = zoom
        fit()
    }

    // A new frame size drags the bounds along with it.
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { fit() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        _ = backing.changed(to: window?.backingScaleFactor)
        fit()
    }

    /// Sent for a new display, and also whenever an ancestor's scale moves:
    /// on every step of a board zoom, and by this view's own `setBoundsSize`.
    /// Only the first is a reason to fit again.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if backing.changed(to: window?.backingScaleFactor) { fit() }
    }

    private func fit() {
        let size = CGSize(width: frame.width * settledZoom, height: frame.height * settledZoom)
        guard size.width > 0, size.height > 0 else { return }
        if bounds.size != size { setBoundsSize(size) }
        let target = alignedContentFrame(size)
        guard !Self.same(target, content.frame) else { return }
        onResize?(target.size)
        content.frame = target
    }

    /// A rect taken to the window and back comes home a few ulps off.
    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        let tolerance: CGFloat = 0.01
        return abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    /// The content's frame, moved onto whole device pixels. The card's origin
    /// is on one, but the body sits a zoomed header and border below it, which
    /// is rarely a whole pixel; left there, the compositor resamples the whole
    /// web view.
    private func alignedContentFrame(_ size: CGSize) -> CGRect {
        let whole = CGRect(origin: .zero, size: size)
        guard let window else { return whole }
        let aligned = window.backingAlignedRect(convert(whole, to: nil), options: .alignAllEdgesNearest)
        return convert(aligned, from: nil)
    }
}
