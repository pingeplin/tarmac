import Foundation
import GhosttyVt

public struct TerminalEngineError: Error, Equatable {
    public let operation: String
    public let code: Int32
}

func check(_ result: GhosttyResult, _ operation: String) throws {
    guard result == GHOSTTY_SUCCESS else {
        throw TerminalEngineError(operation: operation, code: result.rawValue)
    }
}

public struct TerminalScrollbar: Equatable, Sendable {
    public var total: Int
    public var offset: Int
    public var visible: Int

    public init(total: Int, offset: Int, visible: Int) {
        self.total = total
        self.offset = offset
        self.visible = visible
    }
}

public enum ViewportScroll: Equatable, Sendable {
    case top
    case bottom
    /// Negative scrolls into history.
    case rows(Int)
}

/// One terminal's emulator state: libghostty-vt parses the PTY byte stream and
/// owns the screen, scrollback and modes. Rendering and input stay ours — this
/// type only answers "what is on screen" and "which bytes does this event send".
@MainActor
public final class TerminalEngine {
    let terminal: GhosttyTerminal
    public let effects = TerminalEffects()

    public private(set) var cols: Int
    public private(set) var rows: Int

    /// ⌥ sends an ESC prefix (readline's meta) instead of composing a character.
    public var optionAsAlt = true

    private(set) lazy var keyEncoder = try? KeyEncoder()
    private(set) lazy var mouseEncoder = try? MouseEncoder()

    public init(cols: Int, rows: Int) throws {
        var handle: GhosttyTerminal?
        try check(ghostty_terminal_new(nil, &handle, UInt16(cols), UInt16(rows)), "terminal_new")
        terminal = handle!
        self.cols = cols
        self.rows = rows
        try effects.install(on: terminal)
        var blink = true
        try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink), "set cursor blink")
        // The option only seeds what a DECSCUSR reset restores, so apply one.
        feed(Array("\u{1b}[0 q".utf8))
    }

    isolated deinit {
        ghostty_terminal_free(terminal)
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { ghostty_terminal_vt_write(terminal, $0.baseAddress, $0.count) }
    }

    public func feed(_ data: Data) {
        data.withUnsafeBytes {
            ghostty_terminal_vt_write(terminal, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
    }

    public func resize(cols: Int, rows: Int, cellWidthPx: Int, cellHeightPx: Int) throws {
        try check(
            ghostty_terminal_resize(terminal, UInt16(cols), UInt16(rows), UInt32(cellWidthPx), UInt32(cellHeightPx)),
            "terminal_resize"
        )
        self.cols = cols
        self.rows = rows
        effects.reportedSize = GhosttySizeReportSize(
            rows: UInt16(rows), columns: UInt16(cols),
            cell_width: UInt32(cellWidthPx), cell_height: UInt32(cellHeightPx)
        )
    }

    /// Caps history by line count alone. An estimate: history is pruned a page at
    /// a time, so somewhat more is kept. The byte cap libghostty-vt starts with is
    /// lifted, since at ~1000 lines it would bind long before any useful limit.
    public func setScrollbackLimit(lines: Int) throws {
        try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil), "clear scrollback bytes")
        var limit = lines
        try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &limit), "set scrollback lines")
    }

    // MARK: program-set state

    public var title: String? { borrowedString(GHOSTTY_TERMINAL_DATA_TITLE) }
    public var workingDirectory: String? { borrowedString(GHOSTTY_TERMINAL_DATA_PWD) }

    public var isMouseTracking: Bool { read(GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, false) }
    public var isViewportAtBottom: Bool { read(GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, true) }
    public var isBracketedPaste: Bool { mode(ghostty_mode_new(2004, false)) }
    public var isFocusReporting: Bool { mode(ghostty_mode_new(1004, false)) }
    /// Non-zero while the program has the kitty keyboard protocol on.
    public var kittyKeyboardFlags: UInt8 { read(GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, UInt8(0)) }
    public var isSynchronizedOutput: Bool { mode(ghostty_mode_new(2026, false)) }

    /// Ends a hold the program never released; the terminal has no clock of its own.
    public func endSynchronizedOutput() {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &config)
    }

    public var isAlternateScreen: Bool {
        read(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, GHOSTTY_TERMINAL_SCREEN_PRIMARY) == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    public var scrollbar: TerminalScrollbar {
        let bar = read(GHOSTTY_TERMINAL_DATA_SCROLLBAR, GhosttyTerminalScrollbar(total: 0, offset: 0, len: 0))
        return TerminalScrollbar(total: Int(bar.total), offset: Int(bar.offset), visible: Int(bar.len))
    }

    public func scrollViewport(_ scroll: ViewportScroll) {
        var behavior = GhosttyTerminalScrollViewport()
        switch scroll {
        case .top: behavior.tag = GHOSTTY_SCROLL_VIEWPORT_TOP
        case .bottom: behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        case .rows(let delta):
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = delta
        }
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    // MARK: host → program encodings that need no event object

    public func encodePaste(_ text: String) -> [UInt8] {
        var input = Array(text.utf8).map { CChar(bitPattern: $0) }
        let bracketed = isBracketedPaste
        var needed = 0
        _ = ghostty_paste_encode(&input, input.count, bracketed, nil, 0, &needed)
        var output = [CChar](repeating: 0, count: needed)
        var written = 0
        guard ghostty_paste_encode(&input, input.count, bracketed, &output, output.count, &written) == GHOSTTY_SUCCESS
        else { return [] }
        return output.prefix(written).map { UInt8(bitPattern: $0) }
    }

    public func encodeFocus(gained: Bool) -> [UInt8] {
        guard isFocusReporting else { return [] }
        var buffer = [CChar](repeating: 0, count: 8)
        var written = 0
        let event = gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST
        guard ghostty_focus_encode(event, &buffer, buffer.count, &written) == GHOSTTY_SUCCESS else { return [] }
        return buffer.prefix(written).map { UInt8(bitPattern: $0) }
    }

    public func plainText() -> String {
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.trim = true
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal, options) == GHOSTTY_SUCCESS,
              let formatter else { return "" }
        defer { ghostty_formatter_free(formatter) }
        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &buffer, &length) == GHOSTTY_SUCCESS,
              let buffer else { return "" }
        defer { ghostty_free(nil, buffer, length) }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
    }

    /// The `lines` screen rows ending at the cursor's row, trailing blanks
    /// trimmed, wherever the viewport is scrolled. Rows, not logical lines: a
    /// soft-wrapped line is reported as the rows it occupies.
    public func tail(lines: Int) -> String {
        let cursorRow = read(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, 0) + Int(read(GHOSTTY_TERMINAL_DATA_CURSOR_Y, UInt16(0)))
        guard let start = screenRef(col: 0, row: max(cursorRow - lines + 1, 0)),
              let end = screenRef(col: cols - 1, row: cursorRow) else { return "" }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.start = start
        selection.end = end
        return withUnsafePointer(to: &selection) { selection in
            var options = GhosttyTerminalSelectionFormatOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
            options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            options.unwrap = false
            options.trim = true
            options.selection = selection
            var buffer: UnsafeMutablePointer<UInt8>?
            var length = 0
            guard ghostty_terminal_selection_format_alloc(terminal, nil, options, &buffer, &length) == GHOSTTY_SUCCESS,
                  let buffer else { return "" }
            defer { ghostty_free(nil, buffer, length) }
            return String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
        }
    }

    private func screenRef(col: Int, row: Int) -> GhosttyGridRef? {
        var target = GhosttyPoint()
        target.tag = GHOSTTY_POINT_TAG_SCREEN
        target.value.coordinate = GhosttyPointCoordinate(x: UInt16(col), y: UInt32(row))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        return ghostty_terminal_grid_ref(terminal, target, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    // MARK: typed reads

    func read<Value>(_ data: GhosttyTerminalData, _ fallback: Value) -> Value {
        var value = fallback
        guard ghostty_terminal_get(terminal, data, &value) == GHOSTTY_SUCCESS else { return fallback }
        return value
    }

    func mode(_ mode: GhosttyMode) -> Bool {
        read(GHOSTTY_TERMINAL_DATA_MODE, GhosttyTerminalModeConfig(mode: mode, value: false)).value
    }

    private func borrowedString(_ data: GhosttyTerminalData) -> String? {
        let value = string(read(data, GhosttyString(ptr: nil, len: 0)))
        return value.isEmpty ? nil : value
    }
}
