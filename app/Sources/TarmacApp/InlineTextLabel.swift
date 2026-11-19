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
        let marks: MarkFaces
        /// What a one-line text field of the base face fits to, so this label
        /// keeps the height and baseline of the text field it replaces.
        let lineHeight: CGFloat

        @MainActor
        init(design: CGFloat) {
            marks = MarkFaces(design: design)
            lineHeight = NSAttributedString(string: " ", attributes: [.font: marks.base]).size().height
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

    var text = InlineText([]) {
        didSet { if text != oldValue { needsDisplay = true } }
    }

    /// The faces are read again on every set, even for the same design size:
    /// a row sets its style again after a theme or font change.
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

    /// The untruncated text's line box: its width, by a text field's fit height.
    var textSize: NSSize { NSSize(width: width(of: text), height: faces.lineHeight) }

    /// What a text field of this text fits to: the line box, rounded up as
    /// `place` rounds it so that `draw` never finds a fitting text too wide,
    /// and the cell insets.
    var fittedSize: NSSize {
        NSSize(width: textSize.width.rounded(.up) + 2 * ChromeLabel.cellInset, height: faces.lineHeight)
    }

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
        CodeBox.draw(
            backingAlignedRect(rect, options: .alignAllEdgesNearest), radius: Self.boxRadius,
            fill: style.boxFill, border: style.boxBorder
        )
    }

    private func width(of text: InlineText) -> CGFloat {
        pieces(text).reduce(0) { $0 + $1.advance }
    }

    private func pieces(_ text: InlineText) -> [Piece] {
        text.runs.map { run in
            var attributes: [NSAttributedString.Key: Any] = [.font: faces.marks.base, .foregroundColor: style.color]
            attributes.merge(faces.marks.attributes(for: run.mark)) { $1 }
            let string = NSAttributedString(string: run.text, attributes: attributes)
            return Piece(string: string, width: string.size().width, boxed: run.mark == .code)
        }
    }
}
