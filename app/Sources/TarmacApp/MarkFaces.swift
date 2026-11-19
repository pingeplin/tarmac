import AppKit
import TarmacKit

/// The faces of inline marks at one design size, for the inbox row's quote and
/// the preview pane alike (specs 2611.0017 D9, 2611.0018 D13): bold is the
/// semibold face; italic is the family's italic face, else the regular face
/// slanted; a link is underlined.
@MainActor
struct MarkFaces {
    /// `obliqueness` slants an upright face standing in for a missing italic.
    private static let obliqueness = 0.2

    let base: NSFont
    let bold: NSFont
    let italic: NSFont?
    /// What a one-line text field of the base face fits to.
    let lineHeight: CGFloat

    init(design: CGFloat) {
        base = Theme.mono(design)
        lineHeight = NSAttributedString(string: " ", attributes: [.font: base]).size().height
        bold = Theme.mono(design, weight: .semibold)
        let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        self.italic = italic.fontDescriptor.symbolicTraits.contains(.italic) ? italic : nil
    }

    /// A one-line text of the base face, for a code box in wrapped text. A
    /// TextKit line of one face has its baseline where a drawn string has it;
    /// only the line heights differ (measured for five faces, issue #434).
    func codeFace() -> CodeSpanBox.Face {
        let storage = NSTextStorage(string: " ", attributes: [.font: base])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        layout.addTextContainer(NSTextContainer(size: NSSize(width: 100, height: 100)))
        return CodeSpanBox.Face(baseline: layout.location(forGlyphAt: 0).y, lineHeight: lineHeight)
    }

    /// What `mark` sets over the base attributes.
    func attributes(for mark: InlineMark) -> [NSAttributedString.Key: Any] {
        switch mark {
        case .bold: [.font: bold]
        case .italic: italic.map { [.font: $0] } ?? [.obliqueness: Self.obliqueness]
        case .link: [.underlineStyle: NSUnderlineStyle.single.rawValue]
        case .plain, .code, .bullet: [:]
        }
    }
}

/// The box behind code: a rounded rect with a 1 px border, drawn inside
/// `rect` (spec 2611.0017 D9).
enum CodeBox {
    static func draw(_ rect: NSRect, radius: CGFloat, fill: NSColor, border: NSColor) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
