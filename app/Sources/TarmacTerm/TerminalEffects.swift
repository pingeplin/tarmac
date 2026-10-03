import Foundation
import GhosttyVt

/// What a terminal asks of its host while it parses output: replies owed to the
/// PTY, and the side effects (bell, title, pwd, clipboard) libghostty-vt leaves
/// to the embedder. libghostty-vt ignores every such sequence unless a callback
/// is installed, so a program that waits on a query reply hangs without these.
@MainActor
public final class TerminalEffects {
    public var onWritePty: (([UInt8]) -> Void)?
    public var onBell: (() -> Void)?
    public var onTitleChanged: (() -> Void)?
    public var onWorkingDirectoryChanged: (() -> Void)?
    public var onClipboardWrite: ((String) -> Void)?
    /// Synchronized output (mode 2026) began or ended. While it holds, the
    /// screen must keep showing the frame captured as the hold began.
    public var onRenderHold: ((Bool) -> Void)?

    var reportedSize = GhosttySizeReportSize(rows: 0, columns: 0, cell_width: 0, cell_height: 0)

    nonisolated init() {}

    func install(on terminal: GhosttyTerminal) throws {
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        try check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata), "set userdata")
        let callbacks: [(GhosttyTerminalOption, UnsafeRawPointer)] = [
            (GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self)),
            (GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self)),
            (GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(titleChanged, to: UnsafeRawPointer.self)),
            (GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(pwdChanged, to: UnsafeRawPointer.self)),
            (GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, unsafeBitCast(deviceAttributes, to: UnsafeRawPointer.self)),
            (GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(sizeReport, to: UnsafeRawPointer.self)),
            (GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(colorScheme, to: UnsafeRawPointer.self)),
            (GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(clipboardWrite, to: UnsafeRawPointer.self)),
            (GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(renderHold, to: UnsafeRawPointer.self)),
        ]
        for (option, callback) in callbacks {
            try check(ghostty_terminal_set(terminal, option, callback), "set callback \(option.rawValue)")
        }
    }
}

/// libghostty-vt calls back synchronously inside `ghostty_terminal_vt_write`,
/// which the engine only ever runs on the main actor.
private func effects(_ userdata: UnsafeMutableRawPointer?, _ body: @MainActor (TerminalEffects) -> Void) {
    read(userdata, ()) { body($0) }
}

private func read<Value: Sendable>(
    _ userdata: UnsafeMutableRawPointer?,
    _ fallback: Value,
    _ body: @MainActor (TerminalEffects) -> Value
) -> Value {
    guard let userdata else { return fallback }
    nonisolated(unsafe) let pointer = userdata
    return MainActor.assumeIsolated {
        body(Unmanaged<TerminalEffects>.fromOpaque(pointer).takeUnretainedValue())
    }
}

private let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
    guard let data, length > 0 else { return }
    let bytes = Array(UnsafeBufferPointer(start: data, count: length))
    effects(userdata) { $0.onWritePty?(bytes) }
}

private let bell: GhosttyTerminalBellFn = { _, userdata in
    effects(userdata) { $0.onBell?() }
}

private let titleChanged: GhosttyTerminalTitleChangedFn = { _, userdata in
    effects(userdata) { $0.onTitleChanged?() }
}

private let renderHold: GhosttyTerminalRenderHoldFn = { _, userdata, held in
    effects(userdata) { $0.onRenderHold?(held) }
}

private let pwdChanged: GhosttyTerminalPwdChangedFn = { _, userdata in
    effects(userdata) { $0.onWorkingDirectoryChanged?() }
}

/// A VT220 with ANSI colour, plus OSC 52 only while the host handles clipboard
/// writes. Shells and editors (fish, vim) block on DA1 at startup, so some
/// answer is mandatory.
private let deviceAttributes: GhosttyTerminalDeviceAttributesFn = { _, userdata, out in
    guard let out else { return false }
    out.pointee.primary.conformance_level = UInt16(GHOSTTY_DA_CONFORMANCE_VT220)
    out.pointee.primary.features.0 = UInt16(GHOSTTY_DA_FEATURE_ANSI_COLOR)
    out.pointee.primary.num_features = 1
    if read(userdata, false, { $0.onClipboardWrite != nil }) {
        out.pointee.primary.features.1 = UInt16(GHOSTTY_DA_FEATURE_CLIPBOARD)
        out.pointee.primary.num_features = 2
    }
    out.pointee.secondary.device_type = UInt16(GHOSTTY_DA_DEVICE_TYPE_VT220)
    out.pointee.secondary.firmware_version = 10
    out.pointee.secondary.rom_cartridge = 0
    out.pointee.tertiary.unit_id = 0
    return true
}

private let sizeReport: GhosttyTerminalSizeFn = { _, userdata, out in
    let size = read(userdata, nil) { $0.reportedSize.columns > 0 ? $0.reportedSize : nil }
    guard let out, let size else { return false }
    out.pointee = size
    return true
}

private let colorScheme: GhosttyTerminalColorSchemeFn = { _, _, out in
    guard let out else { return false }
    out.pointee = GHOSTTY_COLOR_SCHEME_DARK
    return true
}

private let clipboardWrite: GhosttyTerminalClipboardWriteFn = { _, userdata, write in
    guard let write else { return }
    let request = write.pointee
    let contents = UnsafeBufferPointer(start: request.contents, count: request.contents_len)
    let text = contents.first { string($0.mime).hasPrefix("text/plain") } ?? contents.first
    let value = text.map { string($0.data) } ?? ""
    let handled = read(userdata, false) { effects in
        guard let handler = effects.onClipboardWrite else { return false }
        handler(value)
        return true
    }
    var reply = GhosttyClipboardWriteReply()
    reply.size = MemoryLayout<GhosttyClipboardWriteReply>.size
    reply.result = handled ? GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS : GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
    request.reply?(write, &reply)
}

func string(_ borrowed: GhosttyString) -> String {
    guard let pointer = borrowed.ptr, borrowed.len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: pointer, count: borrowed.len), as: UTF8.self)
}
