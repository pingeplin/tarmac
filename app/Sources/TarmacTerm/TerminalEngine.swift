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

/// One terminal's emulator state: libghostty-vt parses the PTY byte stream and
/// owns the screen, scrollback and modes. Rendering and input stay ours — this
/// type only answers "what is on screen" and "which bytes does this event send".
@MainActor
public final class TerminalEngine {
    let terminal: GhosttyTerminal

    public init(cols: Int, rows: Int) throws {
        var handle: GhosttyTerminal?
        try check(ghostty_terminal_new(nil, &handle, UInt16(cols), UInt16(rows)), "terminal_new")
        terminal = handle!
    }

    isolated deinit {
        ghostty_terminal_free(terminal)
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { ghostty_terminal_vt_write(terminal, $0.baseAddress, $0.count) }
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
}
