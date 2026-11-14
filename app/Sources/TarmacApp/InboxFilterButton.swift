import AppKit
import TarmacKit

/// A filter chip of the inbox, or its `clear all read`: a 1 px border and
/// mono text, as the card header's chips are; the active filter takes the
/// agent colour. Not `HeaderButton`, which is sized by the board's zoom.
@MainActor
final class InboxFilterButton: NSView {
    var onClick: (() -> Void)?
    private let label = OverlayLabel()
    private let text: String

    private enum Metric {
        static let padX: CGFloat = 6
        static let padY: CGFloat = 2
    }

    private static var font: NSFont { Theme.mono(10) }

    override var isFlipped: Bool { true }

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setActive(_ active: Bool) {
        layer?.borderColor = (active ? Theme.agent : Theme.lineSoft).cgColor
        label.attributedStringValue = NSAttributedString(
            string: text, attributes: [.font: Self.font, .foregroundColor: active ? Theme.agent : Theme.muted]
        )
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let size = label.fittedSize
        return NSSize(width: size.width + Metric.padX * 2, height: size.height + Metric.padY * 2)
    }

    override func layout() {
        super.layout()
        let size = label.fittedSize
        label.frame = NSRect(x: Metric.padX, y: Metric.padY, width: size.width, height: size.height)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
