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
        /// A chrome design size (`Theme.mono`).
        var design: CGFloat
        var color: NSColor
        var boxFill: NSColor
        var boxBorder: NSColor
    }

    /// A text field's cell draws its text this far inside its frame; this view
    /// does the same, so it lines up with the text fields beside it.
    static let cellInset: CGFloat = 2
    private static let boxPad: CGFloat = 3
    private static let boxRadius: CGFloat = 3
    /// The slant of an upright face standing in for a missing italic, as the
    /// board switcher slants its hint.
    private static let obliqueness = 0.2

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

    /// The height a one-line text field of the base font fits to, so a label
    /// swapped for this one keeps its height and baseline.
    var lineHeight: CGFloat {
        NSAttributedString(string: " ", attributes: [.font: Theme.mono(style.design)]).size().height
    }

    /// The whole text, as a text field fits it: its runs, box paddings and cell
    /// insets, by `lineHeight`.
    var naturalSize: NSSize { NSSize(width: width(of: text) + 2 * Self.cellInset, height: lineHeight) }

    override func draw(_ dirtyRect: NSRect) {
        var x = Self.cellInset
        for (run, string, width) in strings(shown) {
            if run.mark == .code {
                let box = NSRect(x: x, y: 0, width: width + 2 * Self.boxPad, height: lineHeight).insetBy(dx: 0.5, dy: 0.5)
                let path = NSBezierPath(roundedRect: box, xRadius: Self.boxRadius, yRadius: Self.boxRadius)
                style.boxFill.setFill()
                path.fill()
                style.boxBorder.setStroke()
                path.lineWidth = 1
                path.stroke()
                x += Self.boxPad
            }
            string.draw(at: NSPoint(x: x, y: 0))
            x += width + (run.mark == .code ? Self.boxPad : 0)
        }
    }

    /// The text cut to the view's width: the most characters that fit, with `…`.
    private var shown: InlineText {
        let room = bounds.width - 2 * Self.cellInset
        guard width(of: text) > room else { return text }
        var fits = 1
        var low = 1
        var high = text.plain.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if width(of: text.prefix(characters: mid)) <= room {
                fits = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return text.prefix(characters: fits)
    }

    private func width(of text: InlineText) -> CGFloat {
        strings(text).reduce(0) { $0 + $1.width + ($1.run.mark == .code ? 2 * Self.boxPad : 0) }
    }

    private func strings(_ text: InlineText) -> [(run: InlineRun, string: NSAttributedString, width: CGFloat)] {
        let base = Theme.mono(style.design)
        let italic = Self.italicFace(base)
        return text.runs.map { run in
            var attributes: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: style.color]
            switch run.mark {
            case .bold: attributes[.font] = Theme.mono(style.design, weight: .semibold)
            case .italic:
                if let italic { attributes[.font] = italic } else { attributes[.obliqueness] = Self.obliqueness }
            case .link: attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case .plain, .code, .bullet: break
            }
            let string = NSAttributedString(string: run.text, attributes: attributes)
            return (run, string, string.size().width)
        }
    }

    /// The family's own italic face, if it has one.
    private static func italicFace(_ base: NSFont) -> NSFont? {
        let face = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        return face.fontDescriptor.symbolicTraits.contains(.italic) ? face : nil
    }
}
