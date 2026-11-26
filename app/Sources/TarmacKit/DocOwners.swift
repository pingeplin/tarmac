/// Provenance on a board: the `term_id` that opened each doc. A doc is its
/// bytes (spec 2611.0034), so two forms of one name keep two owners.
public struct DocOwners: Sendable {
    private var termByPath: [DocPath: String] = [:]

    public init() {}

    public subscript(path: String) -> String? {
        get { termByPath[DocPath(path)] }
        set { termByPath[DocPath(path)] = newValue }
    }
}
