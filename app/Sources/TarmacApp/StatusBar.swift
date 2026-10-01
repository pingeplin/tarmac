import AppKit
import TarmacKit

/// Bottom status bar (crib §6 / migration-plan Phase 3): a 27px strip, bg1, a
/// 1px line-soft top border, 10.5px mono faint. Left shows `▞ board` with the
/// `▞` glyph in agent cyan; right shows live counts
/// `N cards on board · M in shelf`.
@MainActor
final class StatusBar: NSView {
    static let height: CGFloat = 27

    private let topBorder = NSView()
    // Left cluster is two labels so the ▞ glyph can be agent cyan while the
    // rest stays faint.
    private let leftGlyph = NSTextField(labelWithString: "▞")
    private let leftLabel = NSTextField(labelWithString: " board")
    // P5 (two honest signals): the daemon-session word (B1–B4 mocks), a second
    // left-cluster span — `attached` in `ok` green when the app holds a live
    // daemon connection, `detached` faint when the link is down. (No tmux — the
    // mock's literal "tmux" word is dropped; daemon-native sessions only.)
    private let sessionLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")
    /// Gap before the session word (CSS `.tm-status` gap:14px).
    private static let sessionGap: CGFloat = 14

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.cgColor

        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = Theme.lineSoft.cgColor
        addSubview(topBorder)

        leftGlyph.font = Theme.mono(10.5)
        leftGlyph.textColor = Theme.agent
        addSubview(leftGlyph)

        leftLabel.font = Theme.mono(10.5)
        leftLabel.textColor = Theme.faint
        addSubview(leftLabel)

        sessionLabel.font = Theme.mono(10.5)
        sessionLabel.textColor = Theme.faint
        addSubview(sessionLabel)

        rightLabel.font = Theme.mono(10.5)
        rightLabel.textColor = Theme.faint
        rightLabel.alignment = .right
        addSubview(rightLabel)

        setCounts(board: 0, shelf: 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// M3: the active board's display name + the board count (`▞ board-3 · 4
    /// boards`). The count is dropped when there is only one board (`▞ board-0`).
    /// A minimal stand-in for P4's full titlebar chip / ⌘K switcher so a switch
    /// is visible.
    func setBoard(_ name: String, count: Int) {
        leftLabel.stringValue = count > 1 ? " \(name) · \(count) boards" : " \(name)"
        needsLayout = true
    }

    func setCounts(board: Int, shelf: Int) {
        let cards = board == 1 ? "1 card on board" : "\(board) cards on board"
        rightLabel.stringValue = "\(cards) · \(shelf) in shelf"
        needsLayout = true
    }

    /// P5: the daemon-session word. `attached` (green) when the app holds a live
    /// daemon connection bound to the active board; `detached` (faint) when the
    /// link is down. App-local — the daemon cannot tell a gone app it detached.
    func setSession(attached: Bool) {
        sessionLabel.stringValue = attached ? "attached" : "detached"
        sessionLabel.textColor = attached ? Theme.ok : Theme.faint
        needsLayout = true
    }

    override func layout() {
        super.layout()
        topBorder.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)

        let h = bounds.height
        let glyphSize = leftGlyph.fittedSize
        leftGlyph.frame = NSRect(
            x: 12,
            y: ((h - glyphSize.height) / 2).rounded(),
            width: glyphSize.width,
            height: glyphSize.height
        )
        let labelSize = leftLabel.fittedSize
        leftLabel.frame = NSRect(
            x: leftGlyph.frame.maxX,
            y: ((h - labelSize.height) / 2).rounded(),
            width: labelSize.width,
            height: labelSize.height
        )

        let sessionSize = sessionLabel.fittedSize
        sessionLabel.frame = NSRect(
            x: leftLabel.frame.maxX + Self.sessionGap,
            y: ((h - sessionSize.height) / 2).rounded(),
            width: sessionSize.width,
            height: sessionSize.height
        )

        let rightSize = rightLabel.fittedSize
        rightLabel.frame = NSRect(
            x: bounds.width - 12 - rightSize.width,
            y: ((h - rightSize.height) / 2).rounded(),
            width: rightSize.width,
            height: rightSize.height
        )
    }
}

/// Cold-start hint (migration-plan Phase 3 / DECISION 2026-06-13): a single
/// centered line shown only while no doc exists yet — `docs appear when
/// anything runs  tarmac open <path>  — you or your tools`, faint 10.5px mono,
/// with the `tarmac open <path>` span in muted. No empty-board placeholder;
/// hidden once the first doc lands. Click-through.
@MainActor
final class ColdStartHintView: NSView {
    private let textField = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        let attr = NSMutableAttributedString()
        let faint: [NSAttributedString.Key: Any] = [.font: Theme.mono(10.5), .foregroundColor: Theme.faint]
        let muted: [NSAttributedString.Key: Any] = [.font: Theme.mono(10.5), .foregroundColor: Theme.muted]
        attr.append(NSAttributedString(string: "docs appear when anything runs  ", attributes: faint))
        attr.append(NSAttributedString(string: "tarmac open <path>", attributes: muted))
        attr.append(NSAttributedString(string: "  — you or your tools", attributes: faint))
        textField.attributedStringValue = attr
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.alignment = .center
        addSubview(textField)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let size = textField.fittedSize
        textField.frame = NSRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }
}
