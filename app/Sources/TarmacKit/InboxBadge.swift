/// The title-bar button's title.
public enum InboxBadge {
    public static func text(unread: Int) -> String {
        switch unread {
        case ...0: "inbox"
        case ...99: "inbox · \(unread)"
        default: "inbox · 99+"
        }
    }
}
