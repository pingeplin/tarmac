extension TermKeyBinding {
    /// The raw `NSEvent.ModifierFlags` bits `bytes(keyCode:modifierFlags:composing:)`
    /// matches on, for a caller that holds the four intent modifiers as flags.
    public static func modifierFlags(shift: Bool, control: Bool, option: Bool, command: Bool) -> UInt {
        (shift ? Self.shift : 0) | (control ? Self.control : 0)
            | (option ? Self.option : 0) | (command ? Self.command : 0)
    }
}
