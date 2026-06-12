import AppKit
import QuartzCore
import SwiftTerm

/// Content view: optional left strip (dock 46px / index 224px), the desk grid
/// (terminal + pinned doc tiles) filling the rest, the peek slide-over above,
/// and the toast overlay on top.
@MainActor
final class RootView: NSView {
    enum LeftStrip {
        case none, dock, index
    }

    let desk = DeskGridView()
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

        addSubview(desk)

        dock.isHidden = true
        addSubview(dock)
        index.isHidden = true
        addSubview(index)

        peek.isHidden = true
        addSubview(peek)
        addSubview(toasts)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func attachTerminal(_ terminal: TerminalView) {
        desk.attachTerminal(terminal)
    }

    /// Dock 46 ↔ index 224 swaps are instant (one terminal reflow per crib
    /// §2.1); only the 0→dock birth slides, and the desk reflow itself is
    /// never animated.
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

    private var leftStripWidth: CGFloat {
        switch leftStrip {
        case .none: return 0
        case .dock: return 46
        case .index: return 224
        }
    }

    override func layout() {
        super.layout()
        dock.frame = NSRect(x: 0, y: 0, width: 46, height: bounds.height)
        index.frame = NSRect(x: 0, y: 0, width: 224, height: bounds.height)
        desk.frame = NSRect(
            x: leftStripWidth,
            y: 0,
            width: max(0, bounds.width - leftStripWidth),
            height: bounds.height
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
