import AppKit
import TarmacKit

/// The zoom control at the board's bottom left: `− | NN% | + | ⊡ fit`.
/// `−` and `+` zoom about the viewport center, `⊡ fit` fits every card into
/// view, and the readout follows the live zoom.
@MainActor
final class ZoomControl: NSView, FontFollowing, ThemeFollowing {
    /// What `−` and `+` divide and multiply the zoom by.
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
    private var separators: [NSView] { [pctLeftBorder, pctRightBorder, fitLeftBorder] }

    private static let padX: CGFloat = 9
    private static let pctPadX: CGFloat = 10
    private static let height: CGFloat = 26
    private static let line: CGFloat = 1

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.masksToBounds = true // clipped (overflow hidden)

        minusBtn.onClick = { [weak self] in self?.onZoomOut?() }
        plusBtn.onClick = { [weak self] in self?.onZoomIn?() }
        fitBtn.onClick = { [weak self] in self?.onFit?() }
        minusBtn.toolTip = "Zoom out"
        plusBtn.toolTip = "Zoom in"
        fitBtn.toolTip = "Fit to cards"

        pct.font = Self.font
        pct.alignment = .center

        for border in separators {
            border.wantsLayer = true
            addSubview(border)
        }
        themeChanged()

        addSubview(minusBtn)
        addSubview(pct)
        addSubview(plusBtn)
        addSubview(fitBtn)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The readout last sized for: a pan reports the viewport on every event
    /// with the zoom unchanged, and measuring the segments is not free.
    private var shownPercent: String?

    fileprivate static var font: NSFont { Theme.mono(10.5) }

    func fontsChanged() {
        pct.font = Self.font
        sizeToContents()
        superview?.needsLayout = true
    }

    func themeChanged() {
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        pct.textColor = Theme.text
        for border in separators { border.layer?.backgroundColor = Theme.lineSoft.cgColor }
    }

    func setZoom(_ zoom: CGFloat) {
        let percent = ChromeText.zoomPercent(Double(zoom))
        guard percent != shownPercent else { return }
        shownPercent = percent
        pct.stringValue = percent
        needsLayout = true
        sizeToContents()
    }

    /// The four segments' widths, left to right: each its text plus padding,
    /// the readout over a 30px floor so it doesn't jitter between 36% and 100%.
    private var segmentWidths: [CGFloat] {
        [
            minusBtn.textWidth + Self.padX * 2,
            max(pct.attributedStringValue.size().width, 30) + Self.pctPadX * 2,
            plusBtn.textWidth + Self.padX * 2,
            fitBtn.textWidth + Self.padX * 2,
        ]
    }

    /// Wraps the control to its contents at the canonical 26px height: the
    /// segments, the 1px separators between them and the border around them.
    func sizeToContents() {
        let total = 2 * Self.line + segmentWidths.reduce(0, +) + 3 * Self.line
        frame = NSRect(x: frame.minX, y: frame.minY, width: total.rounded(.up), height: Self.height)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height - 2 * Self.line
        let segments: [NSView] = [minusBtn, pct, plusBtn, fitBtn]
        var x = Self.line
        for (index, width) in segmentWidths.enumerated() {
            let left = x.rounded()
            x += width
            let right = index == segments.count - 1 ? bounds.width - Self.line : x.rounded()
            segments[index].frame = NSRect(x: left, y: Self.line, width: right - left, height: h)
            guard index < separators.count else { continue }
            separators[index].frame = NSRect(x: right, y: Self.line, width: Self.line, height: h)
            x += Self.line
        }
        // A text field draws from its top, so the readout is centred by its frame.
        let pctHeight = pct.fittedSize.height
        pct.frame = NSRect(
            x: pct.frame.minX, y: Self.line + ((h - pctHeight) / 2).rounded(),
            width: pct.frame.width, height: pctHeight
        )
    }
}

/// One tappable segment of the zoom control (`− + ⊡ fit`). Faint 10.5px mono;
/// owns its mouse so a click never starts a board gesture.
@MainActor
final class ZoomSegmentButton: NSView, FontFollowing, ThemeFollowing {
    var onClick: (() -> Void)?

    private let label: NSTextField

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = ZoomControl.font
        label.alignment = .center
        addSubview(label)
        themeChanged()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func themeChanged() {
        label.textColor = Theme.faint
    }

    func fontsChanged() {
        label.font = ZoomControl.font
        needsLayout = true
    }

    /// The text's advance. A centred label's fitted width is 8pt more than
    /// that, which would make every segment 8pt wider than its stylesheet box.
    var textWidth: CGFloat { label.attributedStringValue.size().width }

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
}

extension ZoomSegmentButton: HoverCursorProviding {
    func hoverCursor(at windowPoint: NSPoint) -> NSCursor { .pointingHand }
}
