import AppKit
import TarmacKit

/// One line of inline-markdown runs (spec 2611.0017 D9, D10). Each run is drawn
/// on its own, as a text field draws its string: one attributed string cannot
/// put a bordered box behind a run, and kern to make room for one moves the
/// caret offsets. A text wider than the view is cut by the kit's rule, so a box
/// always closes before `…`.
@MainActor
final class InlineTextLabel: NSView {
    struct Style {
        var design: CGFloat
        var color: NSColor
        var boxFill: NSColor
        var boxBorder: NSColor
    }

    /// The faces a style's design size resolves to, read once per `style`:
    /// the label is measured several times for each cut.
    private struct Faces {
        let base: NSFont
        let bold: NSFont
        let italic: NSFont?
        /// What a one-line text field of `base` fits to, so this label keeps
        /// the height and baseline of the text field it replaces.
        let lineHeight: CGFloat

        @MainActor
        init(design: CGFloat) {
            base = Theme.mono(design)
            bold = Theme.mono(design, weight: .semibold)
            let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            self.italic = italic.fontDescriptor.symbolicTraits.contains(.italic) ? italic : nil
            lineHeight = NSAttributedString(string: " ", attributes: [.font: base]).size().height
        }
    }

    private struct Piece {
        let string: NSAttributedString
        let width: CGFloat
        let boxed: Bool

        var advance: CGFloat { width + (boxed ? 2 * InlineTextLabel.boxPad : 0) }
    }

    private nonisolated static let boxPad: CGFloat = 3
    private static let boxRadius: CGFloat = 3
    /// `obliqueness` slants an upright face standing in for a missing italic.
    private static let obliqueness = 0.2

    var text = InlineText([]) {
        didSet { if text != oldValue { needsDisplay = true } }
    }

    /// Set again on every theme or font change, so the faces are read again
    /// even when the design size is the same.
    var style: Style {
        didSet {
            faces = Faces(design: style.design)
            needsDisplay = true
        }
    }

    private var faces: Faces

    override var isFlipped: Bool { true }

    init(style: Style) {
        self.style = style
        faces = Faces(design: style.design)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text.plain }

    /// The untruncated text's line box, as `ChromeLabel.textSize`.
    var textSize: NSSize { NSSize(width: width(of: text), height: faces.lineHeight) }

    /// What a text field of this text fits to: the line box and the cell insets.
    var fittedSize: NSSize { NSSize(width: textSize.width + 2 * ChromeLabel.cellInset, height: faces.lineHeight) }

    /// Puts the line box's top-left corner at `origin`, as `ChromeLabel.place`.
    func place(at origin: CGPoint) {
        frame = NSRect(
            x: origin.x.rounded() - ChromeLabel.cellInset, y: origin.y.rounded(),
            width: textSize.width.rounded(.up) + 2 * ChromeLabel.cellInset, height: faces.lineHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let shown = text.prefix(fitting: bounds.width - 2 * ChromeLabel.cellInset, measure: width(of:))
        var x = ChromeLabel.cellInset
        for piece in pieces(shown) {
            if piece.boxed { drawBox(NSRect(x: x, y: 0, width: piece.advance, height: faces.lineHeight)) }
            piece.string.draw(at: NSPoint(x: x + (piece.boxed ? Self.boxPad : 0), y: 0))
            x += piece.advance
        }
    }

    private func drawBox(_ rect: NSRect) {
        let box = backingAlignedRect(rect, options: .alignAllEdgesNearest).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: Self.boxRadius, yRadius: Self.boxRadius)
        style.boxFill.setFill()
        path.fill()
        style.boxBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func width(of text: InlineText) -> CGFloat {
        pieces(text).reduce(0) { $0 + $1.advance }
    }

    private func pieces(_ text: InlineText) -> [Piece] {
        text.runs.map { run in
            var attributes: [NSAttributedString.Key: Any] = [.font: faces.base, .foregroundColor: style.color]
            switch run.mark {
            case .bold: attributes[.font] = faces.bold
            case .italic:
                if let italic = faces.italic { attributes[.font] = italic } else { attributes[.obliqueness] = Self.obliqueness }
            case .link: attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case .plain, .code, .bullet: break
            }
            let string = NSAttributedString(string: run.text, attributes: attributes)
            return Piece(string: string, width: string.size().width, boxed: run.mark == .code)
        }
    }
}
