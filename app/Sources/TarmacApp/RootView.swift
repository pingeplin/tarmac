import AppKit
import QuartzCore
import SwiftTerm

/// Content view: the infinite whiteboard (`BoardView`) fills the window, with the
/// dock/index left rails, the peek slide-over, and the toast overlay layered on
/// top (their removal is Phase 3 — kept as-is here per the Phase 2c scope).
@MainActor
final class RootView: NSView {
    enum LeftStrip {
        case none, dock, index
    }

    let board = BoardView()
    let dock = DockView()
    let index = IndexView()
    let peek = PeekPanel()
    let toasts = ToastStackView()

    private(set) var peekVisible = false
    private(set) var leftStrip: LeftStrip = .none
    private var peekAnimating = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor

        addSubview(board)

        dock.isHidden = true
        addSubview(dock)
        index.isHidden = true
        addSubview(index)

        peek.isHidden = true
        addSubview(peek)
        addSubview(toasts)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func attachTerminal(_ terminal: TerminalView, worldFrame: CardFrame) {
        board.setTerminal(terminal, worldFrame: worldFrame)
    }

    /// Dock 46 ↔ index 224 swaps are instant; only the 0→dock birth slides.
    /// (Dock/index are Phase 3 removals; the board fills the full width — the
    /// rails float above its left edge rather than insetting it.)
    func setLeftStrip(_ strip: LeftStrip, birth: Bool = false) {
        guard strip != leftStrip else { return }
        leftStrip = strip
        dock.isHidden = strip != .dock
        index.isHidden = strip != .index
        needsLayout = true
        layoutSubtreeIfNeeded()

        if birth, strip == .dock, !Theme.reduceMotion {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = -46
            slide.toValue = 0
            slide.duration = 0.22
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            dock.layer?.add(slide, forKey: "dockBirth")
        }
    }

    override func layout() {
        super.layout()
        // The board is the infinite canvas — it fills the window. Dock/index are
        // overlay rails on the left (Phase 3 retires them entirely).
        board.frame = bounds
        dock.frame = NSRect(x: 0, y: 0, width: 46, height: bounds.height)
        index.frame = NSRect(x: 0, y: 0, width: 224, height: bounds.height)
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
