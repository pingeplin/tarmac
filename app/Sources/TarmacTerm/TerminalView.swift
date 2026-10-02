import AppKit
import GhosttyVt

/// A key press as host policy sees it, before the terminal encodes it.
public struct TerminalKeyChord: Equatable, Sendable {
    public var keyCode: UInt16
    public var mods: KeyMods
    public var isComposing: Bool
    public var kittyFlags: UInt8
    public var hasSelection: Bool

    public init(keyCode: UInt16, mods: KeyMods, isComposing: Bool, kittyFlags: UInt8, hasSelection: Bool) {
        self.keyCode = keyCode
        self.mods = mods
        self.isComposing = isComposing
        self.kittyFlags = kittyFlags
        self.hasSelection = hasSelection
    }
}

/// A terminal surface: libghostty-vt holds the emulator state; this view draws
/// it with CoreText and turns AppKit events into PTY bytes. It owns no PTY —
/// output is `feed`, and everything the user does leaves through `onInput`.
///
/// Layout is in the view's own bounds, so a host that scales the view (the
/// board's zoom) never changes cols×rows; only a real resize does.
@MainActor
public final class TerminalView: NSView {
    public var onInput: (([UInt8]) -> Void)?
    public var onResize: ((_ cols: Int, _ rows: Int) -> Void)?
    public var onTitleChanged: ((String?) -> Void)?
    public var onBell: (() -> Void)?
    /// The user typed or clicked here.
    public var onActivity: (() -> Void)?
    /// The user clicked a URL in the output or an OSC 8 hyperlink.
    public var onOpenLink: ((String) -> Void)?
    /// A program asked to set the clipboard (OSC 52). Unset, the request is dropped:
    /// whether a program may overwrite the user's clipboard is the host's call.
    public var onClipboardWrite: ((String) -> Void)? {
        didSet { engine.effects.onClipboardWrite = onClipboardWrite }
    }
    /// Host key policy consulted before the encoder; non-nil bytes are sent as-is.
    public var keyOverride: ((TerminalKeyChord) -> [UInt8]?)?

    public let engine: TerminalEngine
    let selection: TerminalSelection
    private let reader: FrameReader
    private var renderer: TerminalRenderer
    private var frameSnapshot: TerminalFrame
    private(set) var gridLayout: TerminalGridLayout?
    /// Counts font rebuilds; each one drops the glyph cache and redraws everything.
    private(set) var fontGeneration = 0
    private var fontScale: CGFloat
    /// What the program was last told. AppKit can take first responder away
    /// without resigning it (a re-parent) and hand it back, which must not
    /// reach the program as a second focus-in.
    private var reportedFocus = false

    public var padding = TerminalPadding.card { didSet { relayout() } }
    private let fontSize: CGFloat

    private var readScheduled = false
    private var holdStarted: Date?
    private static let maxHold: TimeInterval = 1

    private var blinkTimer: Timer?
    private var blinkOn = true
    private static let blinkInterval: TimeInterval = 0.6

    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?

    private struct LinkHit: Equatable {
        var row: Int
        var link: RowLink
    }

    private var hoveredLink: LinkHit? {
        didSet {
            for row in [oldValue?.row, hoveredLink?.row] {
                if let row { setNeedsDisplay(damageRect(forRow: row)) }
            }
        }
    }
    private var pressedButtons = 0
    private var scrollRemainder: CGFloat = 0
    private var autoscrollTimer: Timer?
    private var lastDragPoint: SurfacePoint?

    public init(
        frame: NSRect = .zero, theme: TerminalTheme = .breeze, fontSize: CGFloat = 16, scrollbackLines: Int = 5000,
        backingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    ) throws {
        engine = try TerminalEngine(cols: 80, rows: 24)
        try engine.apply(theme)
        try engine.setScrollbackLimit(lines: scrollbackLines)
        selection = try TerminalSelection(engine: engine)
        selection.multiClickInterval = NSEvent.doubleClickInterval
        reader = try FrameReader()
        self.fontSize = fontSize
        fontScale = backingScale
        renderer = TerminalRenderer(fonts: TerminalFonts(size: fontSize, pixelsPerPoint: backingScale), theme: theme)
        frameSnapshot = reader.read(engine)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        wireEffects()
        relayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TerminalView is created in code") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public var cols: Int { engine.cols }
    public var rows: Int { engine.rows }
    public var hasSelection: Bool { selection.text != nil }
    public var selectedText: String? { selection.text }
    public var isFocused: Bool { window?.firstResponder === self }

    // MARK: output

    public func feed(_ data: Data) {
        engine.feed(data)
        scheduleRead()
    }

    /// Feeds output recorded earlier. Its queries, bells and clipboard writes
    /// were for a moment that has passed, so only the screen comes back.
    public func replay(_ data: Data) {
        let effects = engine.effects
        let live = (effects.onWritePty, effects.onBell, effects.onClipboardWrite)
        (effects.onWritePty, effects.onBell, effects.onClipboardWrite) = (nil, nil, nil)
        defer { (effects.onWritePty, effects.onBell, effects.onClipboardWrite) = live }
        feed(data)
    }

    public func plainText() -> String { engine.plainText() }

    /// The viewport's cells by their text, row by row; an unwritten cell and the
    /// second column of a wide character are both empty.
    public func viewportCells() -> [[String]] {
        if readScheduled { readIfNotHeld() }
        return frameSnapshot.rows.map { $0.cells.map(\.text) }
    }

    /// A cell's rect in this view's coordinates, or nil outside the grid.
    public func cellRect(col: Int, row: Int) -> NSRect? {
        guard let gridLayout, (0..<gridLayout.cols).contains(col), (0..<gridLayout.rows).contains(row)
        else { return nil }
        return gridLayout.rect(col: col, row: row)
    }

    /// Whether a click at `point`, in this view's coordinates, lands on a link.
    public func hasLink(at point: NSPoint) -> Bool {
        gridLayout.map { link(at: $0.surfacePoint(point)) != nil } ?? false
    }

    /// Clears the terminal before the host replays history into it.
    public func reset() {
        selection.clear()
        holdStarted = nil
        engine.reset()
        scheduleRead()
    }

    private func wireEffects() {
        engine.effects.onWritePty = { [weak self] in self?.onInput?($0) }
        engine.effects.onBell = { [weak self] in self?.onBell?() }
        engine.effects.onTitleChanged = { [weak self] in
            guard let self else { return }
            self.onTitleChanged?(self.engine.title)
        }
        engine.effects.onRenderHold = { [weak self] held in
            guard let self else { return }
            if held {
                // The frame the program wants left on screen is the one current
                // right now; nothing after the hold began has been applied yet.
                self.readFrame()
                self.holdStarted = Date()
            } else {
                self.holdStarted = nil
                self.scheduleRead()
            }
        }
    }

    private func scheduleRead() {
        guard !readScheduled else { return }
        readScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.readScheduled = false
            self.readIfNotHeld()
        }
    }

    private func readIfNotHeld() {
        if let holdStarted {
            let remaining = Self.maxHold - Date().timeIntervalSince(holdStarted)
            guard remaining <= 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in self?.readIfNotHeld() }
                return
            }
            self.holdStarted = nil
            engine.endSynchronizedOutput()
        }
        readFrame()
    }

    private func readFrame() {
        let previousCursor = frameSnapshot.cursor
        frameSnapshot = reader.read(engine)
        guard gridLayout != nil else { return }
        if frameSnapshot.dirtyRows.count >= frameSnapshot.rows.count {
            needsDisplay = true
        } else {
            var rows = frameSnapshot.dirtyRows
            if previousCursor != frameSnapshot.cursor {
                for cursor in [previousCursor, frameSnapshot.cursor] {
                    if let cursor { rows.insert(cursor.row) }
                }
            }
            for row in rows { setNeedsDisplay(damageRect(forRow: row)) }
        }
        restartBlink()
    }

    // MARK: layout

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        relayout()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Also called on every frame-to-bounds scale change (each board zoom
        // step) and after every re-parent; only a new display density matters.
        let scale = window?.backingScaleFactor ?? fontScale
        guard scale != fontScale else { return }
        fontScale = scale
        renderer = TerminalRenderer(fonts: TerminalFonts(size: fontSize, pixelsPerPoint: scale), theme: renderer.theme)
        fontGeneration += 1
        relayout()
    }

    private func relayout() {
        let layout = TerminalGridLayout(bounds: bounds.size, cell: renderer.fonts.metrics.cell, padding: padding)
        defer { gridLayout = layout; needsDisplay = true }
        guard let layout, layout.cols != engine.cols || layout.rows != engine.rows || gridLayout?.cell != layout.cell
        else { return }
        let surface = layout.surface
        try? engine.resize(
            cols: layout.cols, rows: layout.rows, cellWidthPx: surface.cellWidth, cellHeightPx: surface.cellHeight
        )
        frameSnapshot = reader.read(engine)
        onResize?(layout.cols, layout.rows)
    }

    // MARK: drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // A layer-backed view can be asked to draw past its bounds.
        let dirtyRect = dirtyRect.intersection(bounds)
        guard !dirtyRect.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        context.setFillColor(frameSnapshot.background.cgColor)
        context.fill(dirtyRect)
        guard let gridLayout else { return }

        let first = Int(((dirtyRect.minY - gridLayout.origin.y) / gridLayout.cell.height).rounded(.down))
        let last = Int(((dirtyRect.maxY - gridLayout.origin.y) / gridLayout.cell.height).rounded(.up))
        let rows = max(first, 0)..<max(min(last, gridLayout.rows), max(first, 0))
        renderer.draw(
            frameSnapshot, rows: rows, layout: gridLayout, cursor: cursorDisplay,
            preedit: markedText.length > 0 ? markedText.string : nil,
            hoveredLink: hoveredLink.map { (row: $0.row, cols: $0.link.cols) }, in: context
        )
    }

    /// What to invalidate to redraw a row. A redraw is clipped to the damaged
    /// rect, and under a fractional zoom a row's edge falls inside a device
    /// pixel, so the damage reaches a point past each edge; the rows it clips
    /// into are redrawn with it.
    func damageRect(forRow row: Int) -> NSRect {
        guard let gridLayout else { return .zero }
        return gridLayout.rowRect(row).insetBy(dx: 0, dy: -1).intersection(bounds)
    }

    private var cursorDisplay: CursorDisplay {
        guard isFocused, window?.isKeyWindow == true else { return .unfocused }
        return blinkOn || frameSnapshot.cursor?.blinks == false ? .focused : .hidden
    }

    private func invalidateCursor() {
        guard let cursor = frameSnapshot.cursor else { return }
        setNeedsDisplay(damageRect(forRow: cursor.row))
    }

    // MARK: focus and blink

    public override func becomeFirstResponder() -> Bool {
        reportFocus(true)
        restartBlink()
        invalidateCursor()
        return true
    }

    public override func resignFirstResponder() -> Bool {
        reportFocus(false)
        unmarkText()
        stopBlink()
        invalidateCursor()
        return true
    }

    private func reportFocus(_ focused: Bool) {
        guard focused != reportedFocus else { return }
        reportedFocus = focused
        send(engine.encodeFocus(gained: focused))
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return stopBlink() }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowKeyStateChanged), name: name, object: window
            )
        }
        viewDidChangeBackingProperties()
    }

    @objc private func windowKeyStateChanged() {
        restartBlink()
        invalidateCursor()
    }

    private func restartBlink() {
        blinkOn = true
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard isFocused, window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: Self.blinkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.blinkOn.toggle()
                self.invalidateCursor()
            }
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true
    }

    public override func viewDidHide() {
        super.viewDidHide()
        stopBlink()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        restartBlink()
    }

    // MARK: sending

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        onInput?(bytes)
    }

    /// Bytes the user typed: besides reaching the PTY they drop the selection
    /// and bring the viewport back to the live screen.
    private func sendTyped(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if hasSelection { selection.clear() }
        if !engine.isViewportAtBottom { engine.scrollViewport(.bottom) }
        scheduleRead()
        send(bytes)
    }

    public func sendText(_ text: String) {
        sendTyped(Array(text.utf8))
    }

    // MARK: keyboard

    public override func keyDown(with event: NSEvent) {
        onActivity?()
        let mods = KeyTranslation.mods(rawFlags: event.modifierFlags.rawValue)
        let chord = TerminalKeyChord(
            keyCode: event.keyCode, mods: mods, isComposing: hasMarkedText(),
            kittyFlags: engine.kittyKeyboardFlags, hasSelection: hasSelection
        )
        if let bytes = keyOverride?(chord) {
            sendTyped(bytes)
            return
        }

        let translationEvent = translationEvent(for: event)
        let composingBefore = hasMarkedText()
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let skipsTextInput = KeyTranslation.skipsTextInput(
            mods: KeyTranslation.mods(rawFlags: event.modifierFlags.rawValue),
            optionAsAlt: engine.optionAsAlt, composing: composingBefore
        )
        if !skipsTextInput { interpretKeyEvents([translationEvent]) }

        let action: KeyAction = event.isARepeat ? .repeat : .press
        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts { sendKey(event, action: action, text: text, composing: false) }
        } else {
            sendKey(
                event, action: action, text: producedText(translationEvent),
                composing: hasMarkedText() || composingBefore
            )
        }
    }

    public override func keyUp(with event: NSEvent) {
        guard !hasMarkedText() else { return }
        sendKey(event, action: .release, text: nil, composing: false)
    }

    public override func flagsChanged(with event: NSEvent) {
        let mods = KeyTranslation.mods(rawFlags: event.modifierFlags.rawValue)
        let pressed: Bool
        switch KeyTranslation.key(forKeyCode: event.keyCode) {
        case GHOSTTY_KEY_SHIFT_LEFT, GHOSTTY_KEY_SHIFT_RIGHT: pressed = mods.contains(.shift)
        case GHOSTTY_KEY_CONTROL_LEFT, GHOSTTY_KEY_CONTROL_RIGHT: pressed = mods.contains(.control)
        case GHOSTTY_KEY_ALT_LEFT, GHOSTTY_KEY_ALT_RIGHT: pressed = mods.contains(.option)
        case GHOSTTY_KEY_META_LEFT, GHOSTTY_KEY_META_RIGHT: pressed = mods.contains(.command)
        case GHOSTTY_KEY_CAPS_LOCK: pressed = mods.contains(.capsLock)
        default: return
        }
        guard !hasMarkedText() else { return }
        send(engine.encode(KeyInput(
            action: pressed ? .press : .release, key: KeyTranslation.key(forKeyCode: event.keyCode), mods: mods
        )))
    }

    /// AppKit offers ⌘ and ⌃ chords here before `keyDown`. The menu owns ⌘ chords
    /// (Copy, Paste, Quit, …) — except plain ⌘C with nothing selected while a
    /// kitty-keyboard program runs, which is that program's own copy key. ⌃↩ and
    /// ⌃/ are taken here because AppKit otherwise swallows them.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, isFocused else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = KeyTranslation.key(forKeyCode: event.keyCode)
        let programCopy = flags == .command && key == GHOSTTY_KEY_C && !hasSelection && engine.kittyKeyboardFlags > 0
        let swallowedControl = flags == .control && (key == GHOSTTY_KEY_ENTER || key == GHOSTTY_KEY_SLASH)
        guard programCopy || swallowedControl else { return false }
        keyDown(with: event)
        return true
    }

    /// With option-as-alt, the layout must not compose a character from ⌥ — the
    /// encoder needs the plain key plus the alt modifier to emit `ESC <key>`.
    private func translationEvent(for event: NSEvent) -> NSEvent {
        guard engine.optionAsAlt, event.modifierFlags.contains(.option) else { return event }
        let flags = event.modifierFlags.subtracting(.option)
        return NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: flags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: KeyTranslation.latinCharacters(keyCode: event.keyCode, shift: flags.contains(.shift))
                ?? event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode
        ) ?? event
    }

    private func producedText(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first, scalar.value < 0x20 {
            return KeyTranslation.text(event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)))
        }
        return KeyTranslation.text(characters)
    }

    private func sendKey(_ event: NSEvent, action: KeyAction, text: String?, composing: Bool) {
        let mods = KeyTranslation.mods(rawFlags: event.modifierFlags.rawValue)
        let text = KeyTranslation.text(text)
        let input = KeyInput(
            action: action,
            key: KeyTranslation.key(forKeyCode: event.keyCode),
            mods: mods,
            consumedMods: KeyTranslation.consumedMods(mods, text: text, optionAsAlt: engine.optionAsAlt),
            text: text,
            unshiftedCodepoint: KeyTranslation.unshiftedCodepoint(
                layout: event.characters(byApplyingModifiers: []),
                latin: KeyTranslation.latinCharacters(keyCode: event.keyCode, shift: false)
            ),
            composing: composing
        )
        let bytes = engine.encode(input)
        if action == .release { send(bytes) } else { sendTyped(bytes) }
    }

    // MARK: edit commands

    @objc public func copy(_ sender: Any?) {
        guard let text = selection.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        onActivity?()
        sendTyped(engine.encodePaste(text))
    }

    @objc public override func selectAll(_ sender: Any?) {
        selection.selectAll()
        scheduleRead()
    }

    // MARK: mouse

    private func surfacePoint(_ event: NSEvent) -> SurfacePoint? {
        gridLayout?.surfacePoint(convert(event.locationInWindow, from: nil))
    }

    /// The program gets the mouse while it tracks it; ⌥ hands a drag back to selection.
    private func programOwnsMouse(_ event: NSEvent) -> Bool {
        engine.isMouseTracking && !event.modifierFlags.contains(.option)
    }

    private func report(_ event: NSEvent, action: MouseAction, button: MouseButton?) {
        guard let gridLayout, let point = surfacePoint(event) else { return }
        // A drag that leaves the grid keeps reporting from its nearest edge.
        let size = gridLayout.gridSize
        let input = MouseInput(
            action: action, button: button,
            mods: KeyTranslation.mods(rawFlags: event.modifierFlags.rawValue),
            x: min(max(point.x, 0), size.width - 1), y: min(max(point.y, 0), size.height - 1),
            anyButtonPressed: pressedButtons > 0
        )
        send(engine.encode(input, surface: gridLayout.surface))
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onActivity?()
        pressedButtons += 1
        if programOwnsMouse(event) { return report(event, action: .press, button: .left) }
        guard let gridLayout, let point = surfacePoint(event) else { return }
        selection.press(point, time: event.timestamp, surface: gridLayout.surface)
        scheduleRead()
    }

    public override func mouseDragged(with event: NSEvent) {
        if programOwnsMouse(event) { return report(event, action: .motion, button: .left) }
        guard let gridLayout, let point = surfacePoint(event) else { return }
        lastDragPoint = point
        selection.drag(point, surface: gridLayout.surface, rectangle: event.modifierFlags.contains(.option))
        updateAutoscroll()
        scheduleRead()
    }

    public override func mouseUp(with event: NSEvent) {
        pressedButtons = max(pressedButtons - 1, 0)
        stopAutoscroll()
        if programOwnsMouse(event) { return report(event, action: .release, button: .left) }
        guard let gridLayout, let point = surfacePoint(event) else { return }
        selection.release(point, surface: gridLayout.surface)
        scheduleRead()
        if event.clickCount == 1, !selection.dragged, let hit = link(at: point) {
            onOpenLink?(hit.link.url)
        }
    }

    // MARK: links

    /// The link under a surface point: an OSC 8 hyperlink if the program set
    /// one there, else a URL spelled out in the row's text.
    private func link(at point: SurfacePoint) -> LinkHit? {
        // Output that arrived this turn has not been read into the frame yet.
        if readScheduled { readIfNotHeld() }
        guard let gridLayout, point.x >= 0, point.y >= 0 else { return nil }
        let col = Int(point.x / gridLayout.cell.width)
        let row = Int(point.y / gridLayout.cell.height)
        guard frameSnapshot.rows.indices.contains(row), col < gridLayout.cols else { return nil }
        if let target = engine.hyperlink(col: col, row: row) {
            var cols = col...col
            while cols.lowerBound > 0, engine.hyperlink(col: cols.lowerBound - 1, row: row) == target {
                cols = (cols.lowerBound - 1)...cols.upperBound
            }
            while cols.upperBound < gridLayout.cols - 1, engine.hyperlink(col: cols.upperBound + 1, row: row) == target {
                cols = cols.lowerBound...(cols.upperBound + 1)
            }
            return LinkHit(row: row, link: RowLink(cols: cols, url: target))
        }
        return TerminalLinks.urls(in: frameSnapshot.rows[row])
            .first { $0.cols.contains(col) }
            .map { LinkHit(row: row, link: $0) }
    }

    private func isTopmost(at event: NSEvent) -> Bool {
        guard let content = window?.contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        return content.hitTest(point) === self
    }

    private func updateHover(_ event: NSEvent) {
        let hit = programOwnsMouse(event) ? nil : surfacePoint(event).flatMap(link(at:))
        if hit != hoveredLink { hoveredLink = hit }
        (hit == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredLink = nil
    }

    /// Copy / Paste / Select All, after selecting the word under the pointer
    /// unless the click landed inside an existing selection. A program that
    /// tracks the mouse gets the right button as a report instead.
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard !programOwnsMouse(event), let gridLayout, let point = surfacePoint(event) else { return nil }
        if readScheduled { readIfNotHeld() }
        let col = Int(point.x / gridLayout.cell.width)
        let row = Int(point.y / gridLayout.cell.height)
        let insideSelection = frameSnapshot.rows.indices.contains(row)
            && frameSnapshot.rows[row].selection?.contains(col) == true
        if !insideSelection {
            selection.selectWord(at: point, surface: gridLayout.surface)
            scheduleRead()
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard programOwnsMouse(event) else { return super.rightMouseDown(with: event) }
        pressedButtons += 1
        report(event, action: .press, button: .right)
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard programOwnsMouse(event) else { return super.rightMouseUp(with: event) }
        pressedButtons = max(pressedButtons - 1, 0)
        report(event, action: .release, button: .right)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        guard programOwnsMouse(event) else { return super.rightMouseDragged(with: event) }
        report(event, action: .motion, button: .right)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard programOwnsMouse(event) else { return super.otherMouseDown(with: event) }
        pressedButtons += 1
        report(event, action: .press, button: .middle)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard programOwnsMouse(event) else { return super.otherMouseUp(with: event) }
        pressedButtons = max(pressedButtons - 1, 0)
        report(event, action: .release, button: .middle)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        ))
    }

    /// Hover reports count as input to a selection-clearing program, so a shown
    /// selection holds them back; a click dismisses it and reports resume.
    public override func mouseMoved(with event: NSEvent) {
        // A tracking area reports moves over the whole view, including where
        // another view lies on top of it.
        guard isTopmost(at: event) else {
            hoveredLink = nil
            return
        }
        updateHover(event)
        guard isFocused, programOwnsMouse(event), !hasSelection else { return }
        report(event, action: .motion, button: nil)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let gridLayout else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * gridLayout.cell.height
        scrollRemainder += delta
        let lines = Int((scrollRemainder / gridLayout.cell.height).rounded(.towardZero))
        guard lines != 0 else { return }
        scrollRemainder -= CGFloat(lines) * gridLayout.cell.height

        if programOwnsMouse(event) {
            for _ in 0..<abs(lines) {
                report(event, action: .press, button: lines > 0 ? .wheelUp : .wheelDown)
            }
        } else if engine.isAlternateScreen {
            // No scrollback here: the wheel walks the program's own view, as arrow keys.
            let key = lines > 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN
            for _ in 0..<abs(lines) { send(engine.encode(KeyInput(key: key))) }
        } else {
            engine.scrollViewport(.rows(-lines))
            scheduleRead()
        }
    }

    // MARK: selection autoscroll

    private func updateAutoscroll() {
        guard selection.autoscroll != .none else { return stopAutoscroll() }
        guard autoscrollTimer == nil else { return }
        autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollTick() }
        }
    }

    private func autoscrollTick() {
        guard let gridLayout, let point = lastDragPoint else { return stopAutoscroll() }
        switch selection.autoscroll {
        case .none: return stopAutoscroll()
        case .up: engine.scrollViewport(.rows(-1))
        case .down: engine.scrollViewport(.rows(1))
        }
        selection.autoscrollTick(point, surface: gridLayout.surface)
        scheduleRead()
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        lastDragPoint = nil
    }
}

extension TerminalView: NSUserInterfaceValidations {
    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): hasSelection
        case #selector(paste(_:)): NSPasteboard.general.string(forType: .string) != nil
        default: true
        }
    }
}

/// IME: the input context composes into `markedText` (drawn as the preedit at
/// the cursor) and commits through `insertText`, which `keyDown` collects so the
/// committed text goes out as one key event.
extension TerminalView: @preconcurrency NSTextInputClient {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        guard !text.isEmpty else { return }
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else {
            sendText(text)
        }
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString: markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String: markedText = NSMutableAttributedString(string: plain)
        default: return
        }
        invalidatePreedit()
    }

    public func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        invalidatePreedit()
    }

    public func hasMarkedText() -> Bool { markedText.length > 0 }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    public func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where the candidate window anchors: the cursor's cell, in screen coordinates.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let gridLayout, let window else { return .zero }
        let cursor = frameSnapshot.cursor
        let cell = gridLayout.rect(col: cursor?.col ?? 0, row: cursor?.row ?? 0)
        return window.convertToScreen(convert(cell, to: nil))
    }

    /// Keys the input context maps to commands (arrows, ⌃A, …) are encoded by
    /// `keyDown` itself; answering here only keeps AppKit from beeping.
    public override func doCommand(by selector: Selector) {}

    private func invalidatePreedit() {
        guard let cursor = frameSnapshot.cursor else { return needsDisplay = true }
        setNeedsDisplay(damageRect(forRow: cursor.row))
    }
}
