/// A terminal card's header label. There is one stored label and the last
/// writer wins: the daemon's foreground process name and a program's own
/// OSC 0/1/2 title each overwrite it, and nothing is remembered to revert to.
/// (`TermTitle` holds the richer OSC > process > shell precedence, which the
/// desktop app never wired.)
public enum TermLabel {
    public static let initial = "shell"

    /// The label after a `term_proc`; an empty name reads as `shell`.
    public static func afterProc(_ name: String) -> String {
        TermTitle.displayLabel(oscTitle: nil, procName: name, shellName: initial)
    }

    /// The label after a program set its title. A blank title — how a program
    /// clears one — is ignored, so `current` stays.
    public static func afterTitle(_ title: String?, current: String) -> String {
        guard let title, !isBlank(title) else { return current }
        return title
    }

    /// Blank as ECMAScript's `String.prototype.trim` sees it: WhiteSpace and
    /// LineTerminator only. That set includes U+FEFF and excludes U+0085, which
    /// `CharacterSet.whitespacesAndNewlines` has the other way round.
    private static func isBlank(_ title: String) -> Bool {
        title.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x2028, 0x2029, 0xFEFF: return true
            default: return scalar.properties.generalCategory == .spaceSeparator
            }
        }
    }
}
