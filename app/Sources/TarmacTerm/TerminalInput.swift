import Foundation
import GhosttyVt

public struct KeyMods: OptionSet, Equatable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let shift = KeyMods(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
    public static let control = KeyMods(rawValue: UInt16(GHOSTTY_MODS_CTRL))
    public static let option = KeyMods(rawValue: UInt16(GHOSTTY_MODS_ALT))
    public static let command = KeyMods(rawValue: UInt16(GHOSTTY_MODS_SUPER))
    public static let capsLock = KeyMods(rawValue: UInt16(GHOSTTY_MODS_CAPS_LOCK))
    public static let numLock = KeyMods(rawValue: UInt16(GHOSTTY_MODS_NUM_LOCK))
    public static let rightShift = KeyMods(rawValue: UInt16(GHOSTTY_MODS_SHIFT_SIDE))
    public static let rightControl = KeyMods(rawValue: UInt16(GHOSTTY_MODS_CTRL_SIDE))
    public static let rightOption = KeyMods(rawValue: UInt16(GHOSTTY_MODS_ALT_SIDE))
    public static let rightCommand = KeyMods(rawValue: UInt16(GHOSTTY_MODS_SUPER_SIDE))
}

enum KeyAction {
    case press, release, `repeat`

    var ghostty: GhosttyKeyAction {
        switch self {
        case .press: GHOSTTY_KEY_ACTION_PRESS
        case .release: GHOSTTY_KEY_ACTION_RELEASE
        case .repeat: GHOSTTY_KEY_ACTION_REPEAT
        }
    }
}

/// A key event in the shape libghostty-vt's encoder wants: the physical key,
/// the text the layout produced for it (never a C0 control or a function-key
/// PUA scalar), and which modifiers that text already consumed.
struct KeyInput {
    var action: KeyAction = .press
    var key: GhosttyKey
    var mods: KeyMods = []
    var consumedMods: KeyMods = []
    var text: String?
    var unshiftedCodepoint: UInt32 = 0
    var composing = false
}

enum MouseButton {
    case left, right, middle, wheelUp, wheelDown

    var ghostty: GhosttyMouseButton {
        switch self {
        case .left: GHOSTTY_MOUSE_BUTTON_LEFT
        case .right: GHOSTTY_MOUSE_BUTTON_RIGHT
        case .middle: GHOSTTY_MOUSE_BUTTON_MIDDLE
        case .wheelUp: GHOSTTY_MOUSE_BUTTON_FOUR
        case .wheelDown: GHOSTTY_MOUSE_BUTTON_FIVE
        }
    }
}

enum MouseAction {
    case press, release, motion

    var ghostty: GhosttyMouseAction {
        switch self {
        case .press: GHOSTTY_MOUSE_ACTION_PRESS
        case .release: GHOSTTY_MOUSE_ACTION_RELEASE
        case .motion: GHOSTTY_MOUSE_ACTION_MOTION
        }
    }
}

/// A pointer event at a surface-space position (points from the grid's top-left).
struct MouseInput {
    var action: MouseAction
    var button: MouseButton?
    var mods: KeyMods = []
    var x: Double
    var y: Double
    var anyButtonPressed = false
}

/// The rendered grid in the same unit as `MouseInput` positions.
struct SurfaceGeometry: Equatable {
    var width: Int
    var height: Int
    var cellWidth: Int
    var cellHeight: Int
}

@MainActor
final class KeyEncoder {
    private let encoder: GhosttyKeyEncoder
    private let event: GhosttyKeyEvent

    init() throws {
        var encoder: GhosttyKeyEncoder?
        try check(ghostty_key_encoder_new(nil, &encoder), "key_encoder_new")
        var event: GhosttyKeyEvent?
        try check(ghostty_key_event_new(nil, &event), "key_event_new")
        self.encoder = encoder!
        self.event = event!
    }

    isolated deinit {
        ghostty_key_event_free(event)
        ghostty_key_encoder_free(encoder)
    }

    func encode(_ input: KeyInput, terminal: GhosttyTerminal, optionAsAlt: Bool) -> [UInt8] {
        // Resets option-as-alt, so that one is applied after it.
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
        var option = optionAsAlt ? GHOSTTY_OPTION_AS_ALT_TRUE : GHOSTTY_OPTION_AS_ALT_FALSE
        ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &option)

        ghostty_key_event_set_action(event, input.action.ghostty)
        ghostty_key_event_set_key(event, input.key)
        ghostty_key_event_set_mods(event, input.mods.rawValue)
        ghostty_key_event_set_consumed_mods(event, input.consumedMods.rawValue)
        ghostty_key_event_set_unshifted_codepoint(event, input.unshiftedCodepoint)
        ghostty_key_event_set_composing(event, input.composing)

        // The event borrows the text, so it must stay alive across the encode.
        var text = Array((input.text ?? "").utf8CString)
        return text.withUnsafeMutableBufferPointer { utf8 in
            ghostty_key_event_set_utf8(event, input.text == nil ? nil : utf8.baseAddress, utf8.count - 1)
            defer { ghostty_key_event_set_utf8(event, nil, 0) }
            return encoded { ghostty_key_encoder_encode(encoder, event, $0, $1, $2) }
        }
    }
}

@MainActor
final class MouseEncoder {
    private let encoder: GhosttyMouseEncoder
    private let event: GhosttyMouseEvent

    init() throws {
        var encoder: GhosttyMouseEncoder?
        try check(ghostty_mouse_encoder_new(nil, &encoder), "mouse_encoder_new")
        var event: GhosttyMouseEvent?
        try check(ghostty_mouse_event_new(nil, &event), "mouse_event_new")
        self.encoder = encoder!
        self.event = event!
        var trackLastCell = true
        ghostty_mouse_encoder_setopt(self.encoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &trackLastCell)
    }

    isolated deinit {
        ghostty_mouse_event_free(event)
        ghostty_mouse_encoder_free(encoder)
    }

    func encode(_ input: MouseInput, surface: SurfaceGeometry, terminal: GhosttyTerminal) -> [UInt8] {
        ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = UInt32(surface.width)
        size.screen_height = UInt32(surface.height)
        size.cell_width = UInt32(max(surface.cellWidth, 1))
        size.cell_height = UInt32(max(surface.cellHeight, 1))
        ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var pressed = input.anyButtonPressed
        ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)

        ghostty_mouse_event_set_action(event, input.action.ghostty)
        if let button = input.button {
            ghostty_mouse_event_set_button(event, button.ghostty)
        } else {
            ghostty_mouse_event_clear_button(event)
        }
        ghostty_mouse_event_set_mods(event, input.mods.rawValue)
        ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: Float(input.x), y: Float(input.y)))
        return encoded { ghostty_mouse_encoder_encode(encoder, event, $0, $1, $2) }
    }
}

/// Runs one of libghostty-vt's "write into a buffer, tell me the size" encoders,
/// growing the buffer once when the sequence does not fit.
private func encoded(
    _ encode: (UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<Int>?) -> GhosttyResult
) -> [UInt8] {
    var buffer = [CChar](repeating: 0, count: 128)
    var written = 0
    var result = encode(&buffer, buffer.count, &written)
    if result == GHOSTTY_OUT_OF_SPACE {
        buffer = [CChar](repeating: 0, count: written)
        result = encode(&buffer, buffer.count, &written)
    }
    guard result == GHOSTTY_SUCCESS else { return [] }
    return buffer.prefix(written).map { UInt8(bitPattern: $0) }
}

extension TerminalEngine {
    func encode(_ input: KeyInput) -> [UInt8] {
        keyEncoder?.encode(input, terminal: terminal, optionAsAlt: optionAsAlt) ?? []
    }

    func encode(_ input: MouseInput, surface: SurfaceGeometry) -> [UInt8] {
        mouseEncoder?.encode(input, surface: surface, terminal: terminal) ?? []
    }
}
