/// The app's copy of `tarmac_protocol::check_resume_cmd` (2611.0011 D7): it
/// refuses to offer a record from a hand-edited or older `state.json`. The
/// length counts Unicode scalars, as Rust counts `char`s: a grapheme count
/// would accept a longer command made of combining marks.
public enum ResumeCommand {
    public static let maxScalars = 256

    /// `cmd` when there is one and `check` accepts it: the one test of a
    /// command the app would offer.
    public static func accepted(_ cmd: String?) -> String? {
        guard let cmd, check(cmd) == nil else { return nil }
        return cmd
    }

    /// Nil when accepted, else the cause, worded as the daemon words it.
    public static func check(_ cmd: String) -> String? {
        let scalars = cmd.unicodeScalars
        if scalars.allSatisfy(\.properties.isWhitespace) { return "empty" }
        if scalars.contains(where: isControl) { return "a control character" }
        if scalars.contains(where: isInvisibleFormat) { return "an invisible format character" }
        if scalars.count > maxScalars { return "over 256 characters" }
        return nil
    }

    /// How `cmd` reads where space is short, the dead card's strip: each
    /// id-like word cut to its first four characters and `…`; every other
    /// character is shown as it is, so a metacharacter is never hidden. Words
    /// are split on single spaces, keeping the spacing.
    public static func display(_ cmd: String) -> String {
        cmd.split(separator: " ", omittingEmptySubsequences: false)
            .map { isIDLike($0) ? "\($0.prefix(4))…" : String($0) }
            .joined(separator: " ")
    }

    /// 13 or more characters, all from `[A-Za-z0-9_-]`, at least one a digit,
    /// and not a flag (RA2).
    private static func isIDLike(_ word: Substring) -> Bool {
        word.count >= 13 && !word.hasPrefix("-") && word.contains(where: \.isASCIIDigit)
            && word.allSatisfy { $0.isASCIIDigit || ($0.isASCII && $0.isLetter) || $0 == "_" || $0 == "-" }
    }

    /// Rust's `char::is_control` (Cc), and the line and paragraph separators.
    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        s.properties.generalCategory == .control || s.value == 0x2028 || s.value == 0x2029
    }

    private static func isInvisibleFormat(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF: true
        default: false
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
