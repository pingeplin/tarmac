import AppKit
import TarmacKit

/// A tile of the Documents pane (spec 2611.0025 D23): a `PictureTile` whose
/// picture is a markdown card with its sidebar on the tile's side, drawn in
/// the colours of the theme in effect.
@MainActor
enum DocSideTile {
    private static let sidebarWidth: CGFloat = 18
    private static let cardInset: CGFloat = 6
    private static let cardCorner: CGFloat = 3
    private static let headerHeight: CGFloat = 6
    /// A line's start in the sidebar, and in the text.
    private static let sidebarLineInset: CGFloat = 3
    private static let textLineInset: CGFloat = 4
    private static let firstLineTop: CGFloat = 4
    private static let lineStep: CGFloat = 5
    private static let lineHeight: CGFloat = 2

    static func button(_ side: DocSidebar.Side) -> NSButton {
        PictureTile.button(title: side.title)
    }

    static func picture(_ side: DocSidebar.Side, on button: NSButton, palette: Palette) {
        button.image = PictureTile.image(selected: false) { draw(side, palette, in: $0) }
        button.alternateImage = PictureTile.image(selected: true) { draw(side, palette, in: $0) }
    }

    /// The card: a header band, the sidebar band with three entries, the
    /// second of them current, and four lines of text in the rest.
    private static func draw(_ side: DocSidebar.Side, _ palette: Palette, in rect: NSRect) {
        Theme.srgb(palette.bg1).setFill()
        rect.fill()

        let card = rect.insetBy(dx: cardInset, dy: cardInset)
        let (header, body) = card.divided(atDistance: headerHeight, from: .minYEdge)
        let (sidebar, text) = body.divided(atDistance: sidebarWidth, from: side == .left ? .minXEdge : .maxXEdge)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: card, xRadius: cardCorner, yRadius: cardCorner).addClip()
        Theme.srgb(palette.bg2).setFill()
        header.fill()
        sidebar.fill()
        NSGraphicsContext.restoreGraphicsState()

        for (index, width) in [10.0, 8, 11].enumerated() {
            Theme.srgb(index == 1 ? palette.agent : palette.faint).setFill()
            line(index, x: sidebar.minX + sidebarLineInset, in: body, width: width)
        }
        Theme.srgb(palette.faint).setFill()
        for (index, width) in [24.0, 28, 20, 26].enumerated() {
            line(index, x: text.minX + textLineInset, in: body, width: width)
        }

        Theme.srgb(palette.line).setStroke()
        let outline = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: cardCorner, yRadius: cardCorner)
        outline.lineWidth = 1
        outline.stroke()
    }

    private static func line(_ index: Int, x: CGFloat, in body: NSRect, width: CGFloat) {
        let y = body.minY + firstLineTop + CGFloat(index) * lineStep
        let radius = lineHeight / 2
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: lineHeight), xRadius: radius, yRadius: radius).fill()
    }
}
