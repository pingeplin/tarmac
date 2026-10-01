import AppKit
import TarmacKit

/// Zoom control (crib §6, Phase 4): a bottom-left horizontal control —
/// `− | [pct] | + | ⊡ fit`. bg2, 1px line border, radius 8, clipped; 10.5px mono
/// faint, with the `.pct` readout in `text` and line-soft borders on its sides
/// and on the fit span's left edge.
///
/// `−`/`+` zoom the board anchored at the viewport center; `⊡ fit` fits all card
/// world frames into view. The readout updates on every viewport change via
/// `setZoom(_:)`.
@MainActor
final class ZoomControl: NSView {
    /// Multiplicative step for `−` / `+` (≈ a comfortable single tap).
    static let zoomStep: CGFloat = 1.2

    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onFit: (() -> Void)?

    private let minusBtn = ZoomSegmentButton(title: "\u{2212}") // U+2212 minus
    private let pct = NSTextField(labelWithString: "100%")
    private let plusBtn = ZoomSegmentButton(title: "+")
    private let fitBtn = ZoomSegmentButton(title: "\u{22A1} fit") // U+22A1 squared dot
    private let pctLeftBorder = NSView()
    private let pctRightBorder = NSView()
    private let fitLeftBorder = NSView()

    private static let padX: CGFloat = 9
    private static let pctPadX: CGFloat = 10
    private static let height: CGFloat = 26

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.masksToBounds = true // clipped (overflow hidden)

        minusBtn.onClick = { [weak self] in self?.onZoomOut?() }
        plusBtn.onClick = { [weak self] in self?.onZoomIn?() }
        fitBtn.onClick = { [weak self] in self?.onFit?() }

        pct.font = Theme.mono(10.5)
        pct.textColor = Theme.text
        pct.alignment = .center

        for border in [pctLeftBorder, pctRightBorder, fitLeftBorder] {
            border.wantsLayer = true
            border.layer?.backgroundColor = Theme.lineSoft.cgColor
            addSubview(border)
        }

        addSubview(minusBtn)
        addSubview(pct)
        addSubview(plusBtn)
        addSubview(fitBtn)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Updates the % readout from the live zoom (crib §6: round(zoom*100) %).
    func setZoom(_ zoom: CGFloat) {
        pct.stringValue = "\(Int((zoom * 100).rounded()))%"
        needsLayout = true
        sizeToContents()
    }

    /// Wraps the control to its contents at the canonical 26px height.
    func sizeToContents() {
        let h = Self.height
        let minusW = minusBtn.fittedWidth + Self.padX * 2
        let plusW = plusBtn.fittedWidth + Self.padX * 2
        // pct keeps a stable min width so it doesn't jitter between 36% / 100%.
        let pctW = max(pct.fittedSize.width, 30) + Self.pctPadX * 2
        let fitW = fitBtn.fittedWidth + Self.padX * 2
        let total = minusW + pctW + plusW + fitW
        frame = NSRect(x: frame.minX, y: frame.minY, width: total.rounded(), height: h)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 0

        let minusW = minusBtn.fittedWidth + Self.padX * 2
        minusBtn.frame = NSRect(x: x, y: 0, width: minusW, height: h)
        x += minusW

        let pctW = max(pct.fittedSize.width, 30) + Self.pctPadX * 2
        pctLeftBorder.frame = NSRect(x: x, y: 0, width: 1, height: h)
        let pctSize = pct.fittedSize
        pct.frame = NSRect(x: x, y: ((h - pctSize.height) / 2).rounded(), width: pctW, height: pctSize.height)
        x += pctW
        pctRightBorder.frame = NSRect(x: x - 1, y: 0, width: 1, height: h)

        let plusW = plusBtn.fittedWidth + Self.padX * 2
        plusBtn.frame = NSRect(x: x, y: 0, width: plusW, height: h)
        x += plusW

        fitLeftBorder.frame = NSRect(x: x, y: 0, width: 1, height: h)
        let fitW = fitBtn.fittedWidth + Self.padX * 2
        fitBtn.frame = NSRect(x: x, y: 0, width: fitW, height: h)
    }
}

/// One tappable segment of the zoom control (`− + ⊡ fit`). Faint 10.5px mono;
/// owns its mouse so a click never starts a board gesture.
@MainActor
final class ZoomSegmentButton: NSView {
    var onClick: (() -> Void)?

    private let label: NSTextField

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = Theme.mono(10.5)
        label.textColor = Theme.faint
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var fittedWidth: CGFloat { label.fittedSize.width }

    override func layout() {
        super.layout()
        let size = label.fittedSize
        label.frame = NSRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's (ZoomControl's) coordinates; it must
        // be converted to our own bounds before testing. Comparing the raw point
        // against local `bounds` only works for a segment at frame origin (0,0) —
        // every other segment mis-hits, so `−`/`+`/`⊡ fit` clicks were dropped.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
