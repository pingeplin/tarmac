import AppKit

/// A picture tile of the Settings window (specs 2610.0007, 2611.0025): a radio
/// button whose picture is above its title. The selected tile has the accent
/// ring and a bold title.
@MainActor
enum PictureTile {
    private static let picture = NSSize(width: 66, height: 44)
    private static let corner: CGFloat = 7
    /// The room around the picture that the ring is drawn in.
    private static let ringRoom: CGFloat = 4
    private static let ringWidth: CGFloat = 2.5

    static func button(title: String) -> NSButton {
        let button = NSButton()
        button.setButtonType(.radio)
        button.isBordered = false
        button.imagePosition = .imageAbove
        let size = NSFont.smallSystemFontSize
        button.attributedTitle = self.title(title, .systemFont(ofSize: size), .secondaryLabelColor)
        button.attributedAlternateTitle = self.title(title, .boldSystemFont(ofSize: size), .labelColor)
        // With an image of its own, a radio button tells the Accessibility
        // API it is a checkbox.
        button.setAccessibilityRole(.radioButton)
        button.setAccessibilitySubrole(nil)
        return button
    }

    private static func title(_ text: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    /// The picture, with the ring when it is selected; `draw` paints the
    /// picture's rect, clipped to its rounded corners.
    static func image(selected: Bool, draw: @escaping (NSRect) -> Void) -> NSImage {
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
            draw(rect)
            return true
        }
    }
}
