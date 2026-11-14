import AppKit

/// The inbox's button in the title bar (2611.0013): `inbox · N`, borderless,
/// in the system's label colour, because the title bar follows the system
/// appearance and not Tarmac's theme. A click toggles the panel, as ⌘I does.
@MainActor
final class InboxTitlebarButton: NSObject {
    var onClick: (() -> Void)?
    /// What the title-bar accessory holds.
    let container = NSView()
    private let button: NSButton

    private static let padX: CGFloat = 8

    init(title: String) {
        button = NSButton(title: title, target: nil, action: nil)
        super.init()
        button.isBordered = false
        button.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(clicked)
        container.addSubview(button)
        setTitle(title)
    }

    func setTitle(_ title: String) {
        button.title = title
        button.sizeToFit()
        let size = button.frame.size
        container.frame = NSRect(x: 0, y: 0, width: size.width + Self.padX * 2, height: max(size.height, 22))
        button.frame.origin = NSPoint(x: Self.padX, y: ((container.frame.height - size.height) / 2).rounded())
    }

    @objc private func clicked() {
        onClick?()
    }
}
