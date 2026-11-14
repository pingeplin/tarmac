/// What a terminal's `spawn_term` carries beside its id, grid and board.
public struct SpawnRequest: Equatable, Sendable {
    /// The folder to start in: a restored terminal's last (2611.0007).
    public var cwd: String?
    /// The persisted terminal this one replaces, whose record it takes.
    public var succeeds: String?
    /// ⌘T: the terminal whose current directory the new one inherits.
    public var inheritCwdFrom: String?

    public init(cwd: String? = nil, succeeds: String? = nil, inheritCwdFrom: String? = nil) {
        self.cwd = cwd
        self.succeeds = succeeds
        self.inheritCwdFrom = inheritCwdFrom
    }
}
