import AppKit
import TarmacKit

/// A tile of the Theme pane (specs 2610.0007, 2610.0008): a `PictureTile`
/// whose picture is a small Tarmac card.
///
/// The picture is drawn from the theme chosen for each appearance, never from
/// the theme in effect, so it shows its own theme whichever one the app has.
@MainActor
enum ThemeTile {
    static func button(_ choice: ThemeChoice) -> NSButton {
        PictureTile.button(title: choice.title)
    }

    /// Draws the tile's two pictures again, from the palette chosen for each
    /// appearance.
    static func picture(_ choice: ThemeChoice, on button: NSButton, palette: (ThemeVariant) -> Palette) {
        let palettes = choice.pictured.map(palette)
        button.image = image(palettes, selected: false)
        button.alternateImage = image(palettes, selected: true)
    }

    /// One strip for each palette, from the left.
    private static func image(_ palettes: [Palette], selected: Bool) -> NSImage {
        PictureTile.image(selected: selected) { rect in
            let strip = rect.width / CGFloat(palettes.count)
            for (index, palette) in palettes.enumerated() {
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: rect.minX + strip * CGFloat(index), y: rect.minY, width: strip, height: rect.height).clip()
                draw(palette, in: rect)
                NSGraphicsContext.restoreGraphicsState()
            }
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
