import AppKit

/// The inbox's button in the title bar (2611.0013): `inbox · N`, borderless,
/// in the system's label colour, because the title bar follows the system
/// appearance and not Tarmac's theme. A click toggles the panel, as ⌘I does.
@MainActor
final class InboxTitlebarButton: NSObject {
    var onClick: (() -> Void)?
    /// What the title-bar accessory holds. AppKit gives it the title bar's
    /// height, so only its width is ours, and the button's flexible margins
    /// keep it centred in whatever height that is, full screen included.
    let container = NSView()
    private let button: NSButton

    private static let padX: CGFloat = 8

    init(title: String) {
        button = PointingHandButton(title: title, target: nil, action: nil)
        super.init()
        button.isBordered = false
        button.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(clicked)
        button.autoresizingMask = [.minYMargin, .maxYMargin]
        container.addSubview(button)
        setTitle(title)
        container.frame.size.height = button.frame.height
        button.frame.origin.x = Self.padX
    }

    func setTitle(_ title: String) {
        button.title = title
        button.sizeToFit()
        container.frame.size.width = button.frame.width + Self.padX * 2
    }

    @objc private func clicked() {
        onClick?()
    }
}

/// The title bar is outside the board, so `HoverCursorRouter` never sees it.
private final class PointingHandButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
