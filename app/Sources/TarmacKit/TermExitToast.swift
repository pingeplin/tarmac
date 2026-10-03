/// The toast a shell's exit raises. Only a failure is announced: the card of a
/// clean exit just goes away.
public enum TermExitToast {
    public static let icon = "›_"

    /// `code` is the daemon's `exit` code: nil for a signal, 0 for a clean exit.
    public static func title(code: Int?) -> String? {
        switch code {
        case nil: return "killed by signal"
        case 0: return nil
        case let code?: return "shell exited · \(code)"
        }
    }
}
