import AppKit
import TarmacKit

/// A tile of the Theme pane (specs 2610.0007, 2610.0008): a radio button
/// whose picture is a small Tarmac card and whose title is under it. The
/// selected tile has the accent ring and a bold title.
///
/// The picture is drawn from the theme chosen for each appearance, never from
/// the theme in effect, so it shows its own theme whichever one the app has.
@MainActor
enum ThemeTile {
    private static let picture = NSSize(width: 66, height: 44)
    private static let corner: CGFloat = 7
    /// The room around the picture that the ring is drawn in.
    private static let ringRoom: CGFloat = 4
    private static let ringWidth: CGFloat = 2.5

    static func button(_ choice: ThemeChoice) -> NSButton {
        let button = NSButton()
        button.setButtonType(.radio)
        button.isBordered = false
        button.imagePosition = .imageAbove
        let size = NSFont.smallSystemFontSize
        button.attributedTitle = title(choice, .systemFont(ofSize: size), .secondaryLabelColor)
        button.attributedAlternateTitle = title(choice, .boldSystemFont(ofSize: size), .labelColor)
        // With an image of its own, a radio button tells the Accessibility
        // API it is a checkbox.
        button.setAccessibilityRole(.radioButton)
        button.setAccessibilitySubrole(nil)
        return button
    }

    /// Draws the tile's two pictures again, from the palette chosen for each
    /// appearance.
    static func picture(_ choice: ThemeChoice, on button: NSButton, palette: @escaping (ThemeVariant) -> Palette) {
        let palettes = choice.pictured.map(palette)
        button.image = image(palettes, selected: false)
        button.alternateImage = image(palettes, selected: true)
    }

    private static func title(_ choice: ThemeChoice, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: choice.title, attributes: [.font: font, .foregroundColor: color])
    }

    /// One strip for each palette, from the left.
    private static func image(_ palettes: [Palette], selected: Bool) -> NSImage {
        let frame = NSRect(origin: .zero, size: picture).insetBy(dx: -ringRoom, dy: -ringRoom)
        return NSImage(size: frame.size, flipped: true) { bounds in
            if selected {
                let inset = ringWidth / 2
                let ring = NSBezierPath(
                    roundedRect: bounds.insetBy(dx: inset, dy: inset),
                    xRadius: corner + ringRoom - inset, yRadius: corner + ringRoom - inset
                )
                ring.lineWidth = ringWidth
                NSColor.controlAccentColor.setStroke()
                ring.stroke()
            }
            let rect = bounds.insetBy(dx: ringRoom, dy: ringRoom)
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
            let strip = rect.width / CGFloat(palettes.count)
            for (index, palette) in palettes.enumerated() {
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: rect.minX + strip * CGFloat(index), y: rect.minY, width: strip, height: rect.height).clip()
                draw(palette, in: rect)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }

    /// The board, and on it a card that runs off the bottom edge: a header,
    /// a terminal body and two lines of text.
    private static func draw(_ palette: Palette, in rect: NSRect) {
        Theme.srgb(palette.bg0).setFill()
        rect.fill()

        let card = NSRect(x: rect.minX + 9, y: rect.minY + 9, width: rect.width - 18, height: rect.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: card, xRadius: 4, yRadius: 4).addClip()
        Theme.srgb(palette.terminal.background).setFill()
        card.fill()
        Theme.srgb(palette.bg2).setFill()
        NSRect(x: card.minX, y: card.minY, width: card.width, height: 8).fill()
        NSGraphicsContext.restoreGraphicsState()

        for (line, color) in [palette.agent, palette.terminal.foreground].enumerated() {
            Theme.srgb(color).setFill()
            let bar = NSRect(x: card.minX + 5, y: card.minY + 13 + CGFloat(line) * 7, width: 26, height: 3)
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
