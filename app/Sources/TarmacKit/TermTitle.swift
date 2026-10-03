/// Pure decision for a terminal card's displayed title, given two title
/// sources: the OSC title a program emits (OSC 0/1/2) and the foreground process
/// name the daemon pushes (`term_proc`). Kept in TarmacKit so the precedence
/// rule is unit-tested away from AppKit; the app reaches it through `TermLabel`.
///
/// Precedence (Ghostty semantics): a non-empty OSC title always wins — a program
/// that set its own window title is showing what it wants shown. When no OSC
/// title is set (the program never set one, or cleared it with `ESC ] 2 ; ST`),
/// fall back to the daemon's foreground process name, and to the shell basename
/// when even that is absent.
public enum TermTitle {
    /// The label to display on the card/dock. A non-empty `oscTitle` wins; else
    /// the foreground `procName` (when non-empty); else the `shellName`.
    public static func displayLabel(oscTitle: String?, procName: String?, shellName: String) -> String {
        if let osc = oscTitle, !osc.isEmpty { return osc }
        if let proc = procName, !proc.isEmpty { return proc }
        return shellName
    }
}
