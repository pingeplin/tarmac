public enum ResumeCommandDisplay {
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
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
