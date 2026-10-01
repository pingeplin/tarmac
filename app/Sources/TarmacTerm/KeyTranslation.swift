import GhosttyVt

/// The AppKit-independent half of turning a key press into a `KeyInput`: which
/// physical key a virtual key code is, which modifiers are down, and what counts
/// as layout-produced text.
enum KeyTranslation {
    static func key(forKeyCode keyCode: UInt16) -> GhosttyKey {
        physicalKeys[keyCode] ?? GHOSTTY_KEY_UNIDENTIFIED
    }

    /// `rawFlags` is `NSEvent.modifierFlags.rawValue`; its low bits name the side.
    static func mods(rawFlags: UInt) -> KeyMods {
        var mods: KeyMods = []
        if rawFlags & (1 << 16) != 0 { mods.insert(.capsLock) }
        if rawFlags & (1 << 17) != 0 { mods.insert(.shift) }
        if rawFlags & (1 << 18) != 0 { mods.insert(.control) }
        if rawFlags & (1 << 19) != 0 { mods.insert(.option) }
        if rawFlags & (1 << 20) != 0 { mods.insert(.command) }
        if rawFlags & 0x04 != 0 { mods.insert(.rightShift) }
        if rawFlags & 0x2000 != 0 { mods.insert(.rightControl) }
        if rawFlags & 0x40 != 0 { mods.insert(.rightOption) }
        if rawFlags & 0x10 != 0 { mods.insert(.rightCommand) }
        return mods
    }

    /// The encoder derives control sequences from the key and mods itself, so C0
    /// controls and AppKit's function-key private-use scalars must not be passed as text.
    static func text(_ characters: String?) -> String? {
        guard let characters, let first = characters.unicodeScalars.first else { return nil }
        if first.value < 0x20 || first.value == 0x7f { return nil }
        if (0xf700...0xf8ff).contains(first.value) { return nil }
        return characters
    }

    static func consumedMods(_ mods: KeyMods, text: String?, optionAsAlt: Bool) -> KeyMods {
        guard text != nil else { return [] }
        var consumed = mods.intersection([.shift, .rightShift])
        if !optionAsAlt { consumed.formUnion(mods.intersection([.option, .rightOption])) }
        return consumed
    }

    private static let physicalKeys: [UInt16: GhosttyKey] = [
        0x00: GHOSTTY_KEY_A, 0x01: GHOSTTY_KEY_S, 0x02: GHOSTTY_KEY_D, 0x03: GHOSTTY_KEY_F,
        0x04: GHOSTTY_KEY_H, 0x05: GHOSTTY_KEY_G, 0x06: GHOSTTY_KEY_Z, 0x07: GHOSTTY_KEY_X,
        0x08: GHOSTTY_KEY_C, 0x09: GHOSTTY_KEY_V, 0x0a: GHOSTTY_KEY_INTL_BACKSLASH, 0x0b: GHOSTTY_KEY_B,
        0x0c: GHOSTTY_KEY_Q, 0x0d: GHOSTTY_KEY_W, 0x0e: GHOSTTY_KEY_E, 0x0f: GHOSTTY_KEY_R,
        0x10: GHOSTTY_KEY_Y, 0x11: GHOSTTY_KEY_T, 0x12: GHOSTTY_KEY_DIGIT_1, 0x13: GHOSTTY_KEY_DIGIT_2,
        0x14: GHOSTTY_KEY_DIGIT_3, 0x15: GHOSTTY_KEY_DIGIT_4, 0x16: GHOSTTY_KEY_DIGIT_6, 0x17: GHOSTTY_KEY_DIGIT_5,
        0x18: GHOSTTY_KEY_EQUAL, 0x19: GHOSTTY_KEY_DIGIT_9, 0x1a: GHOSTTY_KEY_DIGIT_7, 0x1b: GHOSTTY_KEY_MINUS,
        0x1c: GHOSTTY_KEY_DIGIT_8, 0x1d: GHOSTTY_KEY_DIGIT_0, 0x1e: GHOSTTY_KEY_BRACKET_RIGHT, 0x1f: GHOSTTY_KEY_O,
        0x20: GHOSTTY_KEY_U, 0x21: GHOSTTY_KEY_BRACKET_LEFT, 0x22: GHOSTTY_KEY_I, 0x23: GHOSTTY_KEY_P,
        0x24: GHOSTTY_KEY_ENTER, 0x25: GHOSTTY_KEY_L, 0x26: GHOSTTY_KEY_J, 0x27: GHOSTTY_KEY_QUOTE,
        0x28: GHOSTTY_KEY_K, 0x29: GHOSTTY_KEY_SEMICOLON, 0x2a: GHOSTTY_KEY_BACKSLASH, 0x2b: GHOSTTY_KEY_COMMA,
        0x2c: GHOSTTY_KEY_SLASH, 0x2d: GHOSTTY_KEY_N, 0x2e: GHOSTTY_KEY_M, 0x2f: GHOSTTY_KEY_PERIOD,
        0x30: GHOSTTY_KEY_TAB, 0x31: GHOSTTY_KEY_SPACE, 0x32: GHOSTTY_KEY_BACKQUOTE, 0x33: GHOSTTY_KEY_BACKSPACE,
        0x35: GHOSTTY_KEY_ESCAPE, 0x36: GHOSTTY_KEY_META_RIGHT, 0x37: GHOSTTY_KEY_META_LEFT,
        0x38: GHOSTTY_KEY_SHIFT_LEFT, 0x39: GHOSTTY_KEY_CAPS_LOCK, 0x3a: GHOSTTY_KEY_ALT_LEFT,
        0x3b: GHOSTTY_KEY_CONTROL_LEFT, 0x3c: GHOSTTY_KEY_SHIFT_RIGHT, 0x3d: GHOSTTY_KEY_ALT_RIGHT,
        0x3e: GHOSTTY_KEY_CONTROL_RIGHT, 0x3f: GHOSTTY_KEY_FN, 0x40: GHOSTTY_KEY_F17,
        0x41: GHOSTTY_KEY_NUMPAD_DECIMAL, 0x43: GHOSTTY_KEY_NUMPAD_MULTIPLY, 0x45: GHOSTTY_KEY_NUMPAD_ADD,
        0x47: GHOSTTY_KEY_NUM_LOCK, 0x48: GHOSTTY_KEY_AUDIO_VOLUME_UP, 0x49: GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
        0x4a: GHOSTTY_KEY_AUDIO_VOLUME_MUTE, 0x4b: GHOSTTY_KEY_NUMPAD_DIVIDE, 0x4c: GHOSTTY_KEY_NUMPAD_ENTER,
        0x4e: GHOSTTY_KEY_NUMPAD_SUBTRACT, 0x4f: GHOSTTY_KEY_F18, 0x50: GHOSTTY_KEY_F19,
        0x51: GHOSTTY_KEY_NUMPAD_EQUAL, 0x52: GHOSTTY_KEY_NUMPAD_0, 0x53: GHOSTTY_KEY_NUMPAD_1,
        0x54: GHOSTTY_KEY_NUMPAD_2, 0x55: GHOSTTY_KEY_NUMPAD_3, 0x56: GHOSTTY_KEY_NUMPAD_4,
        0x57: GHOSTTY_KEY_NUMPAD_5, 0x58: GHOSTTY_KEY_NUMPAD_6, 0x59: GHOSTTY_KEY_NUMPAD_7,
        0x5a: GHOSTTY_KEY_F20, 0x5b: GHOSTTY_KEY_NUMPAD_8, 0x5c: GHOSTTY_KEY_NUMPAD_9,
        0x5d: GHOSTTY_KEY_INTL_YEN, 0x5e: GHOSTTY_KEY_INTL_RO, 0x5f: GHOSTTY_KEY_NUMPAD_COMMA,
        0x60: GHOSTTY_KEY_F5, 0x61: GHOSTTY_KEY_F6, 0x62: GHOSTTY_KEY_F7, 0x63: GHOSTTY_KEY_F3,
        0x64: GHOSTTY_KEY_F8, 0x65: GHOSTTY_KEY_F9, 0x66: GHOSTTY_KEY_NON_CONVERT, 0x67: GHOSTTY_KEY_F11,
        0x68: GHOSTTY_KEY_KANA_MODE, 0x69: GHOSTTY_KEY_F13, 0x6a: GHOSTTY_KEY_F16, 0x6b: GHOSTTY_KEY_F14,
        0x6d: GHOSTTY_KEY_F10, 0x6e: GHOSTTY_KEY_CONTEXT_MENU, 0x6f: GHOSTTY_KEY_F12, 0x71: GHOSTTY_KEY_F15,
        0x72: GHOSTTY_KEY_HELP, 0x73: GHOSTTY_KEY_HOME, 0x74: GHOSTTY_KEY_PAGE_UP, 0x75: GHOSTTY_KEY_DELETE,
        0x76: GHOSTTY_KEY_F4, 0x77: GHOSTTY_KEY_END, 0x78: GHOSTTY_KEY_F2, 0x79: GHOSTTY_KEY_PAGE_DOWN,
        0x7a: GHOSTTY_KEY_F1, 0x7b: GHOSTTY_KEY_ARROW_LEFT, 0x7c: GHOSTTY_KEY_ARROW_RIGHT,
        0x7d: GHOSTTY_KEY_ARROW_DOWN, 0x7e: GHOSTTY_KEY_ARROW_UP,
    ]
}
