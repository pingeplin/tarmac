import AppKit
import TarmacKit

/// One desk slot: the terminal sentinel or a pinned doc by registry path.
enum TileKey: Hashable {
    case term
    case doc(String)
}

/// The desk (crib-desk-tiles §1): grid of tiles templated by count, terminal
/// as a peer tile, header drag-swap. Owns the tile order (view of the
/// daemon-persisted layout) and drag-in-progress state; committed mutations
/// fire onOrderChanged, restore applies silently via setTiles.
@MainActor
final class DeskGridView: NSView {
    var onOrderChanged: (() -> Void)?
    var docContent: ((String) -> String)?

    private(set) var order: [TileKey] = [.term]
    private var tiles: [TileKey: TileView] = [:]
    private var docs: [String: RestoreDoc] = [:]

    private struct Drag {
        let key: TileKey
        let start: NSPoint
        var target: TileKey?
    }
    private var drag: Drag?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg0.cgColor
        let termTile = TileView(key: .term)
        tiles[.term] = termTile
        wireDrag(termTile)
        addSubview(termTile)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Order

    var pinnedPaths: [String] {
        order.compactMap {
            if case .doc(let path) = $0 { return path }
            return nil
        }
    }

    /// Pin cap (crib §1 DECISION): 4 tiles total, terminal included.
    var isFull: Bool { order.count >= 4 }

    func isPinned(_ path: String) -> Bool {
        order.contains(.doc(path))
    }

    /// Restore: rebuild silently (no layout echo, no animations).
    func setTiles(order newOrder: [TileKey]) {
        var seen = Set<TileKey>()
        var normalized = newOrder.filter { seen.insert($0).inserted }
        if !normalized.contains(.term) {
            normalized.insert(.term, at: 0)
        }
        applyOrder(normalized)
    }

    /// Appends at the end of the order (crib §4: the new tile takes the last
    /// slot of the new template).
    func pin(_ path: String) {
        let key = TileKey.doc(path)
        guard !order.contains(key) else { return }
        applyOrder(order + [key])
        onOrderChanged?()
    }

    func unpin(_ path: String) {
        let key = TileKey.doc(path)
        guard order.contains(key) else { return }
        applyOrder(order.filter { $0 != key })
        onOrderChanged?()
    }

    private func applyOrder(_ newOrder: [TileKey]) {
        _ = cancelDrag()
        for (key, tile) in tiles where key != .term && !newOrder.contains(key) {
            tile.removeFromSuperview()
            tiles[key] = nil
        }
        for key in newOrder where tiles[key] == nil {
            guard case .doc(let path) = key else { continue }
            let tile = TileView(key: key)
            tile.header.unpinButton?.onClick = { [weak self] in self?.unpin(path) }
            wireDrag(tile)
            if let doc = docs[path] {
                tile.header.apply(doc: doc)
            }
            tile.docView?.render(markdown: docContent?(path) ?? "")
            tiles[key] = tile
            addSubview(tile)
        }
        order = newOrder
        needsLayout = true
    }

    // MARK: - Content

    func attachTerminal(_ terminal: NSView) {
        tiles[.term]?.termBody?.attach(terminal)
    }

    func setTermLabel(_ label: String) {
        tiles[.term]?.header.setLabel(label)
    }

    func update(docs newDocs: [RestoreDoc]) {
        docs = Dictionary(uniqueKeysWithValues: newDocs.map { ($0.path, $0) })
        for (key, tile) in tiles {
            guard case .doc(let path) = key, let doc = docs[path] else { continue }
            tile.header.apply(doc: doc)
        }
    }

    func renderDoc(path: String, markdown: String) {
        tiles[.doc(path)]?.docView?.render(markdown: markdown)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let frames = DeskLayout.frames(count: order.count, in: bounds)
        for (i, key) in order.enumerated() {
            // The dragged tile keeps its slot frame; it is only visually
            // translated above its siblings (crib §5).
            guard drag?.key != key, let tile = tiles[key] else { continue }
            tile.frame = frames[i]
        }
    }

    // MARK: - Drag-swap (crib §5)

    private func wireDrag(_ tile: TileView) {
        tile.header.onMouseDown = { [weak self, weak tile] event in
            guard let self, let tile else { return }
            self.beginDrag(tile: tile, event: event)
        }
        tile.header.onMouseDragged = { [weak self] event in
            self?.updateDrag(event)
        }
        tile.header.onMouseUp = { [weak self] _ in
            self?.endDrag(commit: true)
        }
    }

    /// No movement threshold: drag state starts on mouse-down; a press-and-
    /// release without movement finds no target and is a no-op.
    private func beginDrag(tile: TileView, event: NSEvent) {
        guard drag == nil else { return }
        drag = Drag(key: tile.key, start: convert(event.locationInWindow, from: nil), target: nil)
        tile.setLifted(true)
    }

    private func updateDrag(_ event: NSEvent) {
        guard var d = drag, let tile = tiles[d.key] else { return }
        let p = convert(event.locationInWindow, from: nil)
        tile.setDragTransform(dx: p.x - d.start.x, dy: p.y - d.start.y)

        var over: TileKey?
        for key in order where key != d.key {
            if let candidate = tiles[key], candidate.frame.contains(p) {
                over = key
                break
            }
        }
        guard over != d.target else { return }
        if let old = d.target { tiles[old]?.setDropTarget(false) }
        if let new = over { tiles[new]?.setDropTarget(true) }
        d.target = over
        drag = d
    }

    /// esc during a drag cancels it (crib §5 DECISION). Returns false when no
    /// drag is active so esc falls through to peek/toast dismissal.
    func cancelDrag() -> Bool {
        guard drag != nil else { return false }
        endDrag(commit: false)
        return true
    }

    private func endDrag(commit: Bool) {
        guard let d = drag else { return }
        drag = nil
        if let tile = tiles[d.key] {
            tile.clearDragTransform()
            tile.setLifted(false)
        }
        // The dragged tile skipped layout passes; re-slot it (a resize may
        // have landed mid-drag).
        needsLayout = true
        guard let target = d.target else { return }
        tiles[target]?.setDropTarget(false)
        guard commit,
              let i = order.firstIndex(of: d.key),
              let j = order.firstIndex(of: target) else { return }
        // Strict slot exchange — never an insert/reorder.
        order.swapAt(i, j)
        onOrderChanged?()
    }
}
