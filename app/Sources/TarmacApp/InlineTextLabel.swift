import AppKit
import CoreText
import TarmacKit

/// One line of inline-markdown runs (spec 2611.0017 D9, D10). Each run is its
/// own CTLine: one attributed line cannot draw a bordered box behind a run, and
/// kern to make room for one moves CoreText's caret offsets. A text wider than
/// the view is cut by the kit's rule, so a box always closes before `…`.
@MainActor
final class InlineTextLabel: NSView {
    struct Style {
        /// A chrome design size (`Theme.mono`).
        var design: CGFloat
        var color: NSColor
        var boxFill: NSColor
        var boxBorder: NSColor
    }

    private static let boxPad: CGFloat = 3
    private static let boxRadius: CGFloat = 3
    private static let italicSlant = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)

    var text = InlineText([]) {
        didSet { needsDisplay = true }
    }

    var style: Style {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The line height a one-line text field of the base font has, so a
    /// label swapped for this one keeps its height and baseline.
    var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: Theme.mono(style.design)) }

    /// The whole text: its runs and box paddings, by `lineHeight`.
    var naturalSize: NSSize { NSSize(width: width(of: text), height: lineHeight) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let baseline = NSLayoutManager().defaultBaselineOffset(for: Theme.mono(style.design))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        var x: CGFloat = 0
        for (run, line, width) in lines(shown) {
            if run.mark == .code {
                let box = CGRect(x: x, y: 0, width: width + 2 * Self.boxPad, height: lineHeight).insetBy(dx: 0.5, dy: 0.5)
                let path = CGPath(
                    roundedRect: box, cornerWidth: Self.boxRadius, cornerHeight: Self.boxRadius, transform: nil
                )
                context.addPath(path)
                context.setFillColor(style.boxFill.cgColor)
                context.fillPath()
                context.addPath(path)
                context.setStrokeColor(style.boxBorder.cgColor)
                context.setLineWidth(1)
                context.strokePath()
                x += Self.boxPad
            }
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            x += width + (run.mark == .code ? Self.boxPad : 0)
        }
    }

    /// The text cut to the view's width: the most characters that fit, with `…`.
    private var shown: InlineText {
        guard width(of: text) > bounds.width else { return text }
        var fits = 1
        var low = 1
        var high = text.plain.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if width(of: text.prefix(characters: mid)) <= bounds.width {
                fits = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return text.prefix(characters: fits)
    }

    private func width(of text: InlineText) -> CGFloat {
        lines(text).reduce(0) { $0 + $1.width + ($1.run.mark == .code ? 2 * Self.boxPad : 0) }
    }

    private func lines(_ text: InlineText) -> [(run: InlineRun, line: CTLine, width: CGFloat)] {
        text.runs.map { run in
            var attributes: [NSAttributedString.Key: Any] = [.font: font(run.mark), .foregroundColor: style.color]
            if run.mark == .link { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: run.text, attributes: attributes))
            return (run, line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
    }

    private func font(_ mark: InlineMark) -> NSFont {
        switch mark {
        case .bold: Theme.mono(style.design, weight: .semibold)
        case .italic: Self.italic(Theme.mono(style.design))
        case .plain, .code, .link, .bullet: Theme.mono(style.design)
        }
    }

    /// The family's italic face, else its upright face slanted: `obliqueness`
    /// is an AppKit attribute that a CTLine does not draw.
    private static func italic(_ base: NSFont) -> NSFont {
        let face = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        if face.fontDescriptor.symbolicTraits.contains(.italic) { return face }
        var slant = italicSlant
        return CTFontCreateWithFontDescriptor(base.fontDescriptor as CTFontDescriptor, base.pointSize, &slant) as NSFont
    }
}
