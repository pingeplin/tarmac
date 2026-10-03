/// One key-down as the app's key tables read it: the facts of an `NSEvent`
/// without AppKit.
///
/// Letters and digits are matched on the character the press produced, so a
/// shortcut follows the keyboard layout; the keys with no character of their
/// own (escape, return, tab, delete, the arrows) are matched on the physical
/// key.
public struct KeyPress: Equatable, Sendable {
    public enum Named: Equatable, Sendable {
        case escape, enter, tab, backspace, arrowUp, arrowDown
    }

    public var keyCode: UInt16
    public var characters: String
    public var charactersIgnoringModifiers: String
    /// `NSEvent.ModifierFlags` raw bits; only the four intent modifiers are read.
    public var modifierFlags: UInt

    public init(keyCode: UInt16, characters: String, charactersIgnoringModifiers: String, modifierFlags: UInt) {
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifierFlags = modifierFlags
    }

    public var command: Bool { modifierFlags & TermKeyBinding.command != 0 }
    public var option: Bool { modifierFlags & TermKeyBinding.option != 0 }
    public var control: Bool { modifierFlags & TermKeyBinding.control != 0 }
    public var shift: Bool { modifierFlags & TermKeyBinding.shift != 0 }

    public var named: Named? {
        switch keyCode {
        case 53: .escape
        case 36, 76: .enter
        case 48: .tab
        case 51: .backspace
        case 126: .arrowUp
        case 125: .arrowDown
        default: nil
        }
    }

    /// What WebKit reports as `KeyboardEvent.key`, the value the web app's
    /// shortcuts compare: the characters the press produced, or under control —
    /// where those are a control code — the character without the modifiers.
    public var key: String {
        control ? charactersIgnoringModifiers : characters
    }

    /// ⌘ with `letter`, in either case. Shift may be held; option and control
    /// may not.
    public func isCommandChord(_ letter: Character) -> Bool {
        command && !option && !control && key.lowercased() == String(letter)
    }

    /// The digit of a ⌘1…⌘9 press.
    public var commandDigit: Int? {
        guard command, !option, !control, key.utf16.count == 1, let digit = Int(key), digit >= 1 else { return nil }
        return digit
    }

    /// The one printable character an unmodified (or shifted) press typed.
    /// One UTF-16 unit, as the web app counts a key's length.
    public var typed: String? {
        guard !command, !option, !control, key.utf16.count == 1,
              let scalar = key.unicodeScalars.first, BoardSwitcher.isTypable(scalar: scalar.value)
        else { return nil }
        return key
    }
}
