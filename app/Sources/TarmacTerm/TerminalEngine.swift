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

    // MARK: program-set state

    public var title: String? { borrowedString(GHOSTTY_TERMINAL_DATA_TITLE) }
    public var workingDirectory: String? { borrowedString(GHOSTTY_TERMINAL_DATA_PWD) }

    public var isMouseTracking: Bool { read(GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, false) }
    public var isViewportAtBottom: Bool { read(GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, true) }
    public var isBracketedPaste: Bool { mode(ghostty_mode_new(2004, false)) }
    public var isFocusReporting: Bool { mode(ghostty_mode_new(1004, false)) }

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
