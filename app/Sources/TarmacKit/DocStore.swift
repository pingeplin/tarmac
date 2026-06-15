import Foundation

/// Display/grouping derivations per docs/archive/m1/crib-state.md §1.1 / §4.1: when the
/// daemon sent no repo, fall back to the parent directory exactly as M0 did so
/// existing colors and paths do not shift.
public extension RestoreDoc {
    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var displayRepoName: String {
        repo ?? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    var repoRelativePath: String {
        if let root = repoRoot, path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return fileName
    }

    var displayPath: String {
        displayRepoName + "/" + repoRelativePath
    }

    /// Grouping identity (crib §1.1): repo_root when present, else the parent
    /// directory path — never the name, so two repos both named `api` stay apart.
    var groupKey: String {
        repoRoot ?? (path as NSString).deletingLastPathComponent
    }

    /// ⌘P recency seed (crib §6): latest of open and change.
    var recencyKey: UInt64 {
        max(lastOpenedMs ?? 0, lastChangedMs ?? 0)
    }
}

/// One index group (crib-dock-index §2.3): first-appearance order, items in
/// dock order.
public struct DocGroup: Equatable, Sendable {
    public var key: String
    public var name: String
    public var colorIndex: Int?
    public var docs: [RestoreDoc]
}

/// App-side mirror of the daemon's doc registry: dock order, per-doc state, and
/// ⌘P recency. Mutated only from daemon messages (plus the optimistic local
/// `markRead`); observers get plain callbacks.
@MainActor
public final class DocStore {
    public private(set) var docs: [RestoreDoc] = []

    /// Membership, order, or per-doc state changed.
    public var onChange: (() -> Void)?
    /// A file_event landed for a registered doc (pulse trigger — fires after
    /// onChange so observers see the updated lastChangedMs).
    public var onFileChange: ((String) -> Void)?

    private var indexByPath: [String: Int] = [:]
    /// Monotonic per-doc recency: bumped by doc_opened/file_event, seeded from
    /// restore by sorting on recencyKey (ties broken by dock order) so a live
    /// bump always outranks restored history.
    private var recencyTicks: [String: UInt64] = [:]
    private var nextTick: UInt64 = 1

    public init() {}

    public var isEmpty: Bool { docs.isEmpty }

    public func doc(for path: String) -> RestoreDoc? {
        indexByPath[path].map { docs[$0] }
    }

    /// ⌘P target; nil with an empty registry.
    public var mostRecentPath: String? {
        var best: (path: String, tick: UInt64)?
        for doc in docs {
            let tick = recencyTicks[doc.path] ?? 0
            if best == nil || tick >= best!.tick {
                best = (doc.path, tick)
            }
        }
        return best?.path
    }

    /// `docs[]` order is the dock order (protocol: normative in M1).
    public func applyRestore(_ entries: [RestoreDoc]) {
        var seen = Set<String>()
        docs = entries.filter { seen.insert($0.path).inserted }
        reindex()
        recencyTicks = [:]
        nextTick = 1
        let seeded = docs.enumerated().sorted { a, b in
            a.element.recencyKey == b.element.recencyKey
                ? a.offset < b.offset
                : a.element.recencyKey < b.element.recencyKey
        }
        for (_, doc) in seeded { bump(doc.path) }
        onChange?()
    }

    /// New docs append; re-opens update in place and never move the dock slot
    /// (crib-dock-index §1.3). Returns true when the doc is new.
    @discardableResult
    public func applyDocOpened(_ doc: RestoreDoc) -> Bool {
        let isNew: Bool
        if let i = indexByPath[doc.path] {
            docs[i] = doc
            isNew = false
        } else {
            docs.append(doc)
            indexByPath[doc.path] = docs.count - 1
            isNew = true
        }
        bump(doc.path)
        onChange?()
        return isNew
    }

    public func applyFileEvent(path: String, mtimeMs: UInt64) {
        guard let i = indexByPath[path] else { return }
        docs[i].lastChangedMs = mtimeMs
        bump(path)
        onChange?()
        onFileChange?(path)
    }

    /// Optimistic local flip; the daemon is persisted via doc_read separately.
    public func markRead(_ path: String) {
        guard let i = indexByPath[path], !docs[i].read else { return }
        docs[i].read = true
        onChange?()
    }

    // MARK: - Derived

    public static let recentWindowMs: UInt64 = 30_000

    /// "Recently changed" (crib-state §3): within 30 s of the last file event.
    public static func isRecent(lastChangedMs: UInt64?, nowMs: UInt64) -> Bool {
        guard let changed = lastChangedMs else { return false }
        return nowMs < changed || nowMs - changed < recentWindowMs
    }

    public static func groups(of docs: [RestoreDoc]) -> [DocGroup] {
        var order: [String] = []
        var byKey: [String: DocGroup] = [:]
        for doc in docs {
            if var group = byKey[doc.groupKey] {
                group.docs.append(doc)
                byKey[doc.groupKey] = group
            } else {
                order.append(doc.groupKey)
                byKey[doc.groupKey] = DocGroup(
                    key: doc.groupKey,
                    name: doc.displayRepoName,
                    colorIndex: doc.repoColor,
                    docs: [doc]
                )
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// Index row labels: basename, falling back to the repo-relative path for
    /// basename collisions within the group (crib-dock-index §2.3 DECISION).
    public static func itemLabels(for group: DocGroup) -> [String] {
        var counts: [String: Int] = [:]
        for doc in group.docs { counts[doc.fileName, default: 0] += 1 }
        return group.docs.map { counts[$0.fileName] == 1 ? $0.fileName : $0.repoRelativePath }
    }

    private func reindex() {
        indexByPath = [:]
        for (i, doc) in docs.enumerated() { indexByPath[doc.path] = i }
    }

    private func bump(_ path: String) {
        recencyTicks[path] = nextTick
        nextTick += 1
    }
}
