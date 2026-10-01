import Foundation
import GhosttyVt

/// A position in surface points, measured from the grid's top-left.
struct SurfacePoint: Equatable {
    var x: Double
    var y: Double
}

enum SelectionAutoscroll: Equatable {
    case none, up, down
}

/// Turns pointer gestures into the terminal's selection. libghostty-vt's gesture
/// state machine decides what a click sequence selects (cells, a word, a line);
/// the result is installed as the terminal-owned selection so it tracks its text
/// through scrolling and shows up in the next frame's rows.
@MainActor
final class TerminalSelection {
    private let engine: TerminalEngine
    private let gesture: GhosttySelectionGesture
    private let pressEvent: GhosttySelectionGestureEvent
    private let dragEvent: GhosttySelectionGestureEvent
    private let releaseEvent: GhosttySelectionGestureEvent
    private let tickEvent: GhosttySelectionGestureEvent

    var multiClickInterval: TimeInterval = 0.5

    init(engine: TerminalEngine) throws {
        self.engine = engine
        var gesture: GhosttySelectionGesture?
        try check(ghostty_selection_gesture_new(nil, &gesture), "selection_gesture_new")
        self.gesture = gesture!
        pressEvent = try Self.event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS)
        dragEvent = try Self.event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG)
        releaseEvent = try Self.event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE)
        tickEvent = try Self.event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK)
    }

    isolated deinit {
        for event in [pressEvent, dragEvent, releaseEvent, tickEvent] {
            ghostty_selection_gesture_event_free(event)
        }
        ghostty_selection_gesture_free(gesture, engine.terminal)
    }

    private static func event(_ type: GhosttySelectionGestureEventType) throws -> GhosttySelectionGestureEvent {
        var event: GhosttySelectionGestureEvent?
        try check(ghostty_selection_gesture_event_new(nil, &event, type), "selection_gesture_event_new")
        return event!
    }

    // MARK: gestures

    func press(_ point: SurfacePoint, time: TimeInterval, surface: SurfaceGeometry) {
        guard var ref = ref(at: point, surface: surface) else { return }
        var position = GhosttySurfacePosition(x: point.x, y: point.y)
        var timeNs = UInt64(max(time, 0) * 1_000_000_000)
        var intervalNs = UInt64(multiClickInterval * 1_000_000_000)
        set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
        set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &timeNs)
        set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &intervalNs)
        apply(pressEvent)
    }

    func drag(_ point: SurfacePoint, surface: SurfaceGeometry, rectangle: Bool = false) {
        guard var ref = ref(at: point, surface: surface) else { return }
        var position = GhosttySurfacePosition(x: point.x, y: point.y)
        var geometry = gestureGeometry(surface)
        var rectangle = rectangle
        set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
        set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
        set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rectangle)
        apply(dragEvent)
    }

    func release(_ point: SurfacePoint, surface: SurfaceGeometry) {
        if var ref = ref(at: point, surface: surface) {
            set(releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        } else {
            ghostty_selection_gesture_event_set(releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, nil)
        }
        ghostty_selection_gesture_event(gesture, engine.terminal, releaseEvent, nil)
    }

    /// Whether the current (or just-released) press turned into a drag.
    var dragged: Bool {
        var dragged = false
        ghostty_selection_gesture_get(gesture, engine.terminal, GHOSTTY_SELECTION_GESTURE_DATA_DRAGGED, &dragged)
        return dragged
    }

    /// Which way a drag held past the grid's edge wants the viewport to scroll.
    var autoscroll: SelectionAutoscroll {
        var direction = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
        ghostty_selection_gesture_get(gesture, engine.terminal, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &direction)
        switch direction {
        case GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_UP: return .up
        case GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_DOWN: return .down
        default: return .none
        }
    }

    /// Extends the selection after the host scrolled the viewport for `autoscroll`.
    func autoscrollTick(_ point: SurfacePoint, surface: SurfaceGeometry) {
        let cell = cell(at: point, surface: surface)
        var viewport = GhosttyPointCoordinate(x: UInt16(cell.col), y: UInt32(cell.row))
        var position = GhosttySurfacePosition(x: point.x, y: point.y)
        var geometry = gestureGeometry(surface)
        set(tickEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &viewport)
        set(tickEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
        set(tickEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
        apply(tickEvent)
    }

    // MARK: whole-selection commands

    func clear() {
        ghostty_selection_gesture_reset(gesture, engine.terminal)
        ghostty_terminal_set(engine.terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
    }

    func selectAll() {
        var selection = Self.emptySelection()
        guard ghostty_terminal_select_all(engine.terminal, &selection) == GHOSTTY_SUCCESS else { return }
        ghostty_terminal_set(engine.terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
    }

    /// The selected text as a copy would take it: soft wraps joined, trailing blanks trimmed.
    var text: String? {
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = true
        options.trim = true
        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_terminal_selection_format_alloc(engine.terminal, nil, options, &buffer, &length) == GHOSTTY_SUCCESS
        else { return nil }
        defer { ghostty_free(nil, buffer, length) }
        guard let buffer, length > 0 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
    }

    // MARK: plumbing

    private func apply(_ event: GhosttySelectionGestureEvent) {
        var selection = Self.emptySelection()
        if ghostty_selection_gesture_event(gesture, engine.terminal, event, &selection) == GHOSTTY_SUCCESS {
            ghostty_terminal_set(engine.terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        } else {
            ghostty_terminal_set(engine.terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        }
    }

    private func set<Value>(_ event: GhosttySelectionGestureEvent, _ option: GhosttySelectionGestureEventOption, _ value: inout Value) {
        ghostty_selection_gesture_event_set(event, option, &value)
    }

    private func cell(at point: SurfacePoint, surface: SurfaceGeometry) -> (col: Int, row: Int) {
        let col = Int((point.x / Double(max(surface.cellWidth, 1))).rounded(.down))
        let row = Int((point.y / Double(max(surface.cellHeight, 1))).rounded(.down))
        return (min(max(col, 0), engine.cols - 1), min(max(row, 0), engine.rows - 1))
    }

    private func ref(at point: SurfacePoint, surface: SurfaceGeometry) -> GhosttyGridRef? {
        let cell = cell(at: point, surface: surface)
        var target = GhosttyPoint()
        target.tag = GHOSTTY_POINT_TAG_VIEWPORT
        target.value.coordinate = GhosttyPointCoordinate(x: UInt16(cell.col), y: UInt32(cell.row))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(engine.terminal, target, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    private func gestureGeometry(_ surface: SurfaceGeometry) -> GhosttySelectionGestureGeometry {
        GhosttySelectionGestureGeometry(
            columns: UInt32(engine.cols),
            cell_width: UInt32(max(surface.cellWidth, 1)),
            padding_left: 0,
            screen_height: UInt32(max(surface.height, 1))
        )
    }

    private static func emptySelection() -> GhosttySelection {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.start.size = MemoryLayout<GhosttyGridRef>.size
        selection.end.size = MemoryLayout<GhosttyGridRef>.size
        return selection
    }
}
