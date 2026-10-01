/// Pure decision for a terminal card's displayed title and its "live"
/// (agent-active) status, given the two title sources the app tracks: the OSC
/// title a program emits (OSC 0/1/2, parsed by SwiftTerm — like Ghostty) and the
/// foreground process name the daemon pushes (`term_proc`). Kept in TarmacKit so
/// the precedence rule is unit-tested away from AppKit; the app
/// (`AppController.handleTermTitle` / `handleTermProc`) only does the wiring.
/// Mirrors the `TermExit` pattern.
///
/// Precedence (Ghostty semantics): a non-empty OSC title always wins — a program
/// that set its own window title is showing what it wants shown. When no OSC
/// title is set (the program never set one, or cleared it with `ESC ] 2 ; ST`),
/// fall back to the daemon's foreground process name, and to the shell basename
/// when even that is absent.
public enum TermTitle {
    /// Whether an OSC title string is an active (displayable) title. Programs
    /// clear the window title by emitting an EMPTY OSC 2 — an empty string is a
    /// "no title" signal, not a title, so it never wins over the process name.
    public static func isActive(oscTitle: String?) -> Bool {
        guard let t = oscTitle else { return false }
        return !t.isEmpty
    }

    /// The label to display on the card/dock. A non-empty `oscTitle` wins; else
    /// the foreground `procName` (when non-empty); else the `shellName`.
    public static func displayLabel(oscTitle: String?, procName: String?, shellName: String) -> String {
        if let osc = oscTitle, !osc.isEmpty { return osc }
        if let proc = procName, !proc.isEmpty { return proc }
        return shellName
    }

    /// Whether the card reads as "live" (agent-active: cyan, crib §6). A program
    /// that set its own OSC title counts as live — it is doing something worth
    /// surfacing. Otherwise fall back to the existing process heuristic: the
    /// foreground process is no longer the bare shell.
    public static func isLive(oscTitle: String?, procName: String?, shellName: String) -> Bool {
        if isActive(oscTitle: oscTitle) { return true }
        guard let proc = procName, !proc.isEmpty else { return false }
        return proc != shellName
    }
}
