import AppKit
import TarmacKit

/// A tile of the Documents pane (spec 2611.0025 D23): a `PictureTile` whose
/// picture is a markdown card with its sidebar on the tile's side, drawn in
/// the colours of the theme in effect.
@MainActor
enum DocSideTile {
    private static let sidebarWidth: CGFloat = 18

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

        let card = rect.insetBy(dx: 6, dy: 6)
        let header = NSRect(x: card.minX, y: card.minY, width: card.width, height: 6)
        let body = NSRect(x: card.minX, y: header.maxY, width: card.width, height: card.height - header.height)
        let sidebar = NSRect(
            x: side == .left ? body.minX : body.maxX - sidebarWidth, y: body.minY,
            width: sidebarWidth, height: body.height
        )
        let textX = side == .left ? sidebar.maxX + 4 : body.minX + 4

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: card, xRadius: 3, yRadius: 3).addClip()
        Theme.srgb(palette.bg2).setFill()
        header.fill()
        sidebar.fill()
        NSGraphicsContext.restoreGraphicsState()

        for (index, width) in [10.0, 8, 11].enumerated() {
            Theme.srgb(index == 1 ? palette.agent : palette.faint).setFill()
            bar(x: sidebar.minX + 3, y: body.minY + 4 + CGFloat(index) * 5, width: width)
        }
        Theme.srgb(palette.faint).setFill()
        for (index, width) in [24.0, 28, 20, 26].enumerated() {
            bar(x: textX, y: body.minY + 4 + CGFloat(index) * 5, width: width)
        }

        Theme.srgb(palette.line).setStroke()
        let outline = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        outline.lineWidth = 1
        outline.stroke()
    }

    private static func bar(x: CGFloat, y: CGFloat, width: CGFloat) {
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 2), xRadius: 1, yRadius: 1).fill()
    }
}
