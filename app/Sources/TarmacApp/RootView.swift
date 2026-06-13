import AppKit
import QuartzCore
import SwiftTerm

/// Content view: the infinite whiteboard (`BoardView`) fills the window above a
/// 27px status bar, with the shelf overlay (top-left), the cold-start hint, the
/// peek slide-over, and the toast overlay layered on top. The dock/index rails
/// were retired in Phase 3 (the shelf replaces the dock).
@MainActor
final class RootView: NSView {
    let board = BoardView()
    let shelf = ShelfView()
    let statusBar = StatusBar()
    let coldStartHint = ColdStartHintView()
    let peek = PeekPanel()
    let toasts = ToastStackView()

    private(set) var peekVisible = false
    private var peekAnimating = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor

        addSubview(board)
        addSubview(statusBar)
        coldStartHint.isHidden = true
        addSubview(coldStartHint)
        // Shelf floats over the board's top-left; hidden until non-empty.
        addSubview(shelf)

        peek.isHidden = true
        addSubview(peek)
        addSubview(toasts)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func attachTerminal(_ terminal: TerminalView, worldFrame: CardFrame) {
        board.setTerminal(terminal, worldFrame: worldFrame)
    }

    /// Board height = window minus the 27px status bar (migration-plan Phase 3).
    private var boardHeight: CGFloat { max(0, bounds.height - StatusBar.height) }

    override func layout() {
        super.layout()
        board.frame = NSRect(x: 0, y: 0, width: bounds.width, height: boardHeight)
        statusBar.frame = NSRect(x: 0, y: boardHeight, width: bounds.width, height: StatusBar.height)
        // Cold-start hint: one line just above the status bar, full width.
        coldStartHint.frame = NSRect(x: 0, y: boardHeight - 28, width: bounds.width, height: 20)
        // The shelf sizes itself (top-left at 12,12); nothing to lay out here.
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
