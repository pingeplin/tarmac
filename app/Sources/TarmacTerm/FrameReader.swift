import Foundation
import GhosttyVt

/// Turns a terminal into `TerminalFrame`s through libghostty-vt's render state,
/// re-reading only the rows it reports dirty and reusing the rest from the
/// previous frame.
@MainActor
final class FrameReader {
    private let state: GhosttyRenderState
    private let iterator: GhosttyRenderStateRowIterator
    private let rowCells: GhosttyRenderStateRowCells
    private var rows: [FrameRow] = []
    private var cols = 0
    /// The default colours of the last frame. A program that sets one or
    /// gives it back (OSC 10, 11, 110, 111) makes no row dirty, and a cell
    /// with no colour of its own is drawn in it. A palette entry needs no
    /// such watch: the library marks every row dirty for a new one.
    private var defaults = (foreground: RGB(0, 0, 0), background: RGB(0, 0, 0))
    private var scalars = [UInt32](repeating: 0, count: 16)

    init() throws {
        var state: GhosttyRenderState?
        try check(ghostty_render_state_new(nil, &state), "render_state_new")
        var iterator: GhosttyRenderStateRowIterator?
        try check(ghostty_render_state_row_iterator_new(nil, &iterator), "row_iterator_new")
        var rowCells: GhosttyRenderStateRowCells?
        try check(ghostty_render_state_row_cells_new(nil, &rowCells), "row_cells_new")
        self.state = state!
        self.iterator = iterator!
        self.rowCells = rowCells!
    }

    isolated deinit {
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(iterator)
        ghostty_render_state_free(state)
    }

    func read(_ engine: TerminalEngine) -> TerminalFrame {
        ghostty_render_state_update(state, engine.terminal)

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)

        let newCols = Int(get(GHOSTTY_RENDER_STATE_DATA_COLS, UInt16(0)))
        let newRows = Int(get(GHOSTTY_RENDER_STATE_DATA_ROWS, UInt16(0)))
        let dirty = get(GHOSTTY_RENDER_STATE_DATA_DIRTY, GHOSTTY_RENDER_STATE_DIRTY_FULL)
        let newDefaults = (foreground: RGB(colors.foreground), background: RGB(colors.background))
        let redrawAll = dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || newCols != cols || newRows != rows.count
            || newDefaults != defaults
        defaults = newDefaults
        if redrawAll {
            cols = newCols
            rows = Array(repeating: FrameRow(cells: [], selection: nil), count: newRows)
        }

        var dirtyRows = IndexSet()
        if redrawAll || dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE {
            var iterator: GhosttyRenderStateRowIterator? = self.iterator
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator)
            var y = 0
            while ghostty_render_state_row_iterator_next(self.iterator), y < rows.count {
                var rowDirty = false
                ghostty_render_state_row_get(self.iterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
                if redrawAll || rowDirty {
                    rows[y] = readRow(palette: &colors)
                    dirtyRows.insert(y)
                }
                y += 1
            }
        }
        ghostty_render_state_clean(state)

        return TerminalFrame(
            cols: cols,
            rows: rows,
            foreground: defaults.foreground,
            background: defaults.background,
            cursorColor: colors.cursor_has_value ? RGB(colors.cursor) : nil,
            cursor: readCursor(),
            dirtyRows: dirtyRows
        )
    }

    private func readCursor() -> FrameCursor? {
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor) == GHOSTTY_SUCCESS,
              cursor.visible, cursor.viewport_has_value else { return nil }
        let shape: CursorShape = switch cursor.visual_style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: .hollowBlock
        default: .block
        }
        return FrameCursor(
            col: Int(cursor.viewport_x), row: Int(cursor.viewport_y),
            shape: shape, blinks: cursor.blinking, onWideTail: cursor.wide_tail
        )
    }

    private func readRow(palette colors: inout GhosttyRenderStateColors) -> FrameRow {
        var cells: GhosttyRenderStateRowCells? = rowCells
        ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)

        var row = FrameRow(cells: [], selection: nil)
        row.cells.reserveCapacity(cols)
        while ghostty_render_state_row_cells_next(rowCells) {
            row.cells.append(readCell(palette: &colors))
        }

        var selection = GhosttyRenderStateRowSelection()
        selection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
        if ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS {
            row.selection = Int(selection.start_x)...Int(selection.end_x)
        }
        return row
    }

    private func readCell(palette colors: inout GhosttyRenderStateColors) -> FrameCell {
        var cell = FrameCell()

        var raw: GhosttyCell = 0
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
        var wide = GHOSTTY_CELL_WIDE_NARROW
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
        cell.width = switch wide {
        case GHOSTTY_CELL_WIDE_WIDE: .wide
        case GHOSTTY_CELL_WIDE_SPACER_TAIL, GHOSTTY_CELL_WIDE_SPACER_HEAD: .spacer
        default: .narrow
        }

        var length: UInt32 = 0
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
        if length > 0 {
            if scalars.count < Int(length) { scalars = [UInt32](repeating: 0, count: Int(length)) }
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &scalars)
            var view = String.UnicodeScalarView()
            for value in scalars.prefix(Int(length)) {
                view.append(Unicode.Scalar(value) ?? "\u{fffd}")
            }
            cell.text = String(view)
        }

        var background = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background) == GHOSTTY_SUCCESS {
            cell.style.background = RGB(background)
        }

        var styled = false
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &styled)
        guard styled else { return cell }

        var foreground = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &foreground) == GHOSTTY_SUCCESS {
            cell.style.foreground = RGB(foreground)
        }
        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
        cell.style.flags = flags(style)
        cell.style.underline = underline(style.underline)
        cell.style.underlineColor = resolve(style.underline_color, palette: &colors)
        return cell
    }

    private func flags(_ style: GhosttyStyle) -> CellFlags {
        var flags: CellFlags = []
        if style.bold { flags.insert(.bold) }
        if style.italic { flags.insert(.italic) }
        if style.faint { flags.insert(.faint) }
        if style.inverse { flags.insert(.inverse) }
        if style.invisible { flags.insert(.invisible) }
        if style.strikethrough { flags.insert(.strikethrough) }
        if style.overline { flags.insert(.overline) }
        if style.blink { flags.insert(.blink) }
        return flags
    }

    private func underline(_ value: Int32) -> UnderlineStyle {
        switch GhosttySgrUnderline(rawValue: value) {
        case GHOSTTY_SGR_UNDERLINE_SINGLE: .single
        case GHOSTTY_SGR_UNDERLINE_DOUBLE: .double
        case GHOSTTY_SGR_UNDERLINE_CURLY: .curly
        case GHOSTTY_SGR_UNDERLINE_DOTTED: .dotted
        case GHOSTTY_SGR_UNDERLINE_DASHED: .dashed
        default: .none
        }
    }

    private func resolve(_ color: GhosttyStyleColor, palette colors: inout GhosttyRenderStateColors) -> RGB? {
        switch color.tag {
        case GHOSTTY_STYLE_COLOR_RGB:
            return RGB(color.value.rgb)
        case GHOSTTY_STYLE_COLOR_PALETTE:
            let index = Int(color.value.palette)
            return withUnsafeBytes(of: &colors.palette) {
                RGB($0.bindMemory(to: GhosttyColorRgb.self)[index])
            }
        default:
            return nil
        }
    }

    private func get<Value>(_ data: GhosttyRenderStateData, _ fallback: Value) -> Value {
        var value = fallback
        guard ghostty_render_state_get(state, data, &value) == GHOSTTY_SUCCESS else { return fallback }
        return value
    }
}
