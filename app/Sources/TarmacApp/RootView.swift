import AppKit
import QuartzCore
import SwiftTerm

/// Content view: bg0 desk with a 12px padding, the terminal tile filling it,
/// the peek slide-over above, and the toast overlay on top.
@MainActor
final class RootView: NSView {
    let terminalTile = NSView()
    let peek = PeekPanel()
    let toasts = ToastStackView()

    private(set) weak var terminalView: TerminalView?
    private(set) var peekVisible = false
    private var peekAnimating = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor

        terminalTile.wantsLayer = true
        terminalTile.layer?.backgroundColor = Theme.termBg.cgColor
        terminalTile.layer?.cornerRadius = 9
        terminalTile.layer?.borderColor = Theme.line.cgColor
        terminalTile.layer?.borderWidth = 1
        addSubview(terminalTile)

        peek.isHidden = true
        addSubview(peek)
        addSubview(toasts)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func attachTerminal(_ terminal: TerminalView) {
        terminalView = terminal
        terminalTile.addSubview(terminal)
    }

    override func layout() {
        super.layout()
        terminalTile.frame = bounds.insetBy(dx: 12, dy: 12)
        // Terminal body padding per crib: 12px vertical, 16px horizontal.
        terminalView?.frame = NSRect(
            x: 16,
            y: 12,
            width: max(0, terminalTile.bounds.width - 32),
            height: max(0, terminalTile.bounds.height - 24)
        )
        if !peekAnimating {
            peek.frame = peekFrame(visible: peekVisible)
        }
        toasts.frame = bounds
    }

    func peekFrame(visible: Bool) -> NSRect {
        let width = (bounds.width * 0.47).rounded()
        // Hidden = translateX(102%) per the design.
        let x = visible ? bounds.width - width : bounds.width + (width * 0.02).rounded()
        return NSRect(x: x, y: 0, width: width, height: bounds.height)
    }

    func setPeekVisible(_ visible: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard visible != peekVisible else {
            completion?()
            return
        }
        peekVisible = visible
        let target = peekFrame(visible: visible)

        if Theme.reduceMotion {
            peek.frame = target
            peek.isHidden = !visible
            completion?()
            return
        }

        peek.isHidden = false
        peek.frame = peekFrame(visible: !visible)
        peek.needsLayout = true
        peekAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            peek.animator().frame = target
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.peekAnimating = false
                self.peek.isHidden = !self.peekVisible
                self.needsLayout = true
                completion?()
            }
        })
    }
}
