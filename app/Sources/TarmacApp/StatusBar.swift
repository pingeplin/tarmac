import AppKit
import TarmacKit

/// The strip under the board: `▞ tarmac`, the daemon link, and on the right the
/// active board's card count.
@MainActor
final class StatusBar: NSView {
    static let height: CGFloat = 27

    private static let padX: CGFloat = 12
    private static let gap: CGFloat = 8
    private static let borderWidth: CGFloat = 1

    private let topBorder = NSView()
    private let glyph = ChromeLabel("▞", size: 10.5, color: Theme.agent)
    private let brand = ChromeLabel("tarmac", size: 10.5, color: Theme.faint)
    private let link = ChromeLabel(size: 10.5, color: Theme.faint)
    private let count = ChromeLabel(size: 10.5, color: Theme.faint)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.cgColor

        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = Theme.lineSoft.cgColor
        addSubview(topBorder)
        for label in [glyph, brand, link, count] { addSubview(label) }

        setCardCount(0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setCardCount(_ cards: Int) {
        count.stringValue = ChromeText.cardCount(cards)
        needsLayout = true
    }

    /// The daemon link: `attached` while connected, else why it is not.
    func setConnection(_ status: ConnectionStatus) {
        link.stringValue = status.label
        link.textColor = status.connected ? Theme.ok : Theme.amber
        needsLayout = true
    }

    override func layout() {
        super.layout()
        topBorder.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.borderWidth)

        let countSize = count.textSize
        let countX = bounds.width - Self.padX - countSize.width
        count.place(at: CGPoint(x: countX, y: rowY(countSize)))

        var x = Self.padX
        for label in [glyph, brand] {
            let size = label.textSize
            label.place(at: CGPoint(x: x, y: rowY(size)))
            x += size.width + Self.gap
        }
        // A long reason gives way to the count instead of running under it.
        let linkSize = link.textSize
        let room = max(0, countX - Self.gap - x)
        link.place(at: CGPoint(x: x, y: rowY(linkSize)), width: min(linkSize.width, room))
    }

    /// Centres a label in the strip below its top border.
    private func rowY(_ size: NSSize) -> CGFloat {
        (Self.borderWidth + (bounds.height - Self.borderWidth - size.height) / 2).rounded()
    }
}
