import Foundation

public extension RestoreDoc {
    var fileName: String {
        (path as NSString).lastPathComponent
    }
}

/// App-side mirror of one board's part of the daemon's doc registry: the docs
/// in the order the daemon lists them, and their per-doc state. Mutated only
/// from daemon messages; the observer gets a plain callback.
@MainActor
public final class DocStore {
    public private(set) var docs: [RestoreDoc] = []

    /// Membership, order, or per-doc state changed.
    public var onChange: (() -> Void)?

    private var indexByPath: [String: Int] = [:]

    public init() {}

    public func doc(for path: String) -> RestoreDoc? {
        indexByPath[path].map { docs[$0] }
    }

    /// Takes the daemon's list in its order, keeping the first entry of a
    /// repeated path.
    public func applyRestore(_ entries: [RestoreDoc]) {
        var seen = Set<String>()
        docs = entries.filter { seen.insert($0.path).inserted }
        reindex()
        onChange?()
    }

    /// New docs append; re-opens update in place and never move. A re-open
    /// keeps the repo, owner and change time its entry leaves out. Returns
    /// true when the doc is new.
    @discardableResult
    public func applyDocOpened(_ doc: RestoreDoc) -> Bool {
        let isNew: Bool
        if let i = indexByPath[doc.path] {
            let previous = docs[i]
            docs[i] = doc
            docs[i].repo = doc.repo ?? previous.repo
            docs[i].repoRoot = doc.repoRoot ?? previous.repoRoot
            docs[i].repoColor = doc.repoColor ?? previous.repoColor
            docs[i].termID = doc.termID ?? previous.termID
            docs[i].lastChangedMs = doc.lastChangedMs ?? previous.lastChangedMs
            isNew = false
        } else {
            docs.append(doc)
            indexByPath[doc.path] = docs.count - 1
            isNew = true
        }
        onChange?()
        return isNew
    }

    /// A closed doc leaves the registry.
    public func remove(_ path: String) {
        guard let i = indexByPath[path] else { return }
        docs.remove(at: i)
        reindex()
        onChange?()
    }

    public func applyFileEvent(path: String, mtimeMs: UInt64) {
        guard let i = indexByPath[path] else { return }
        docs[i].lastChangedMs = mtimeMs
        onChange?()
    }

    private func reindex() {
        indexByPath = [:]
        for (i, doc) in docs.enumerated() { indexByPath[doc.path] = i }
    }
}
