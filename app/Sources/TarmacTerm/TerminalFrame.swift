import Foundation

public enum CellWidth: Equatable, Sendable {
    case narrow
    case wide
    /// The second column of a wide cell (or the wrapped-wide placeholder): draw nothing.
    case spacer
}

public enum UnderlineStyle: Equatable, Sendable {
    case none, single, double, curly, dotted, dashed
}

public struct CellFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold = CellFlags(rawValue: 1 << 0)
    public static let italic = CellFlags(rawValue: 1 << 1)
    public static let faint = CellFlags(rawValue: 1 << 2)
    public static let inverse = CellFlags(rawValue: 1 << 3)
    public static let invisible = CellFlags(rawValue: 1 << 4)
    public static let strikethrough = CellFlags(rawValue: 1 << 5)
    public static let overline = CellFlags(rawValue: 1 << 6)
    public static let blink = CellFlags(rawValue: 1 << 7)
}

/// nil colours mean "the frame's default"; a colour of the palette is already
/// resolved, so a new theme reaches it only through a new frame.
public struct CellStyle: Equatable, Sendable {
    public var foreground: RGB?
    public var background: RGB?
    public var underlineColor: RGB?
    public var underline: UnderlineStyle = .none
    public var flags: CellFlags = []

    public init() {}
}

public struct FrameCell: Equatable, Sendable {
    public var text: String = ""
    public var width: CellWidth = .narrow
    public var style = CellStyle()

    public init() {}
}

public struct FrameRow: Equatable, Sendable {
    public var cells: [FrameCell]
    /// Inclusive column range covered by the selection on this row.
    public var selection: ClosedRange<Int>?

    public var text: String {
        var line = cells.reduce(into: "") { $0 += $1.width == .spacer ? "" : ($1.text.isEmpty ? " " : $1.text) }
        while line.last == " " { line.removeLast() }
        return line
    }
}

public enum CursorShape: Equatable, Sendable {
    case block, hollowBlock, bar, underline
}

public struct FrameCursor: Equatable, Sendable {
    public var col: Int
    public var row: Int
    public var shape: CursorShape
    public var blinks: Bool
    /// The cursor sits on the second column of a wide cell: draw it one column left, two wide.
    public var onWideTail: Bool
}

/// Everything one draw needs, copied out of libghostty-vt so drawing never
/// touches the emulator. `dirtyRows` names the rows that a draw shows
/// differently from the previous frame this reader produced: every row when
/// a default colour changed.
public struct TerminalFrame: Equatable, Sendable {
    public var cols: Int
    public var rows: [FrameRow]
    public var foreground: RGB
    public var background: RGB
    public var cursorColor: RGB?
    /// nil when the program hid the cursor or it is scrolled out of the viewport.
    public var cursor: FrameCursor?
    public var dirtyRows: IndexSet
}

/// The input method's uncommitted text, and where its caret is in it.
struct TerminalPreedit: Equatable {
    var text: String
    /// A UTF-16 offset into `text`, as the input method counts.
    var caret: Int
}
