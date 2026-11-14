import CoreGraphics

/// The cards a board is built from the first time its `restore` arrives.
public enum BoardRestore {
    public struct Term: Equatable, Sendable {
        public var termID: String
        public var frame: CGRect
        public var z: Int
        /// Nil for a terminal re-bound to a PTY the daemon still owns.
        public var spawn: SpawnRequest?

        public var needsSpawn: Bool { spawn != nil }

        public init(termID: String, frame: CGRect, z: Int, spawn: SpawnRequest?) {
            self.termID = termID
            self.frame = frame
            self.z = z
            self.spawn = spawn
        }
    }

    public struct Doc: Equatable, Sendable {
        public var path: String
        public var frame: CGRect
        public var z: Int
        public var ownerTermID: String?
        public var attached: Bool

        public init(path: String, frame: CGRect, z: Int, ownerTermID: String?, attached: Bool) {
            self.path = path
            self.frame = frame
            self.z = z
            self.ownerTermID = ownerTermID
            self.attached = attached
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Never empty. The first terminal is prime.
        public var terms: [Term]
        public var docs: [Doc]
        /// Doc tiles whose path the board's registry does not know.
        public var droppedDocPaths: [String]

        public init(terms: [Term], docs: [Doc], droppedDocPaths: [String]) {
            self.terms = terms
            self.docs = docs
            self.droppedDocPaths = droppedDocPaths
        }
    }

    /// `tiles` and `docs` are the restore's layout and doc registry; `liveTerms`
    /// the terminals the daemon still owns. `mint` supplies the id of every
    /// terminal that cold-spawns — a persisted id is never reused for a new shell.
    /// A cold spawn of a persisted tile succeeds its persisted id, and starts in
    /// that terminal's last folder in `termRecords` (2611.0007).
    ///
    /// A doc follows its recorded owner to whatever that terminal was restored
    /// as. An owner that was not restored leaves the doc ownerless and detached;
    /// there is no fallback to the board's only terminal.
    public static func plan(
        tiles: [LayoutTile], docs: [RestoreDoc], liveTerms: Set<String>, termRecords: [String: TermRecord] = [:],
        mint: () -> String
    ) -> Plan {
        let parsed = LayoutTiles.parse(tiles)
        let rebinds = TermRestore.plan(tileTermIDs: parsed.terms.map(\.termID), liveTerms: liveTerms)

        var restoredID: [String: String] = [:]
        var terms: [Term] = []
        for (index, tile) in parsed.terms.enumerated() {
            let termID: String
            let spawn: SpawnRequest?
            switch rebinds[index] {
            case .rebind(let live):
                (termID, spawn) = (live, nil)
            case .coldSpawn:
                let cwd = tile.termID.flatMap { termRecords[$0]?.lastCwd }
                (termID, spawn) = (mint(), SpawnRequest(cwd: cwd, succeeds: tile.termID))
            }
            if let persisted = tile.termID { restoredID[persisted] = termID }
            terms.append(Term(
                termID: termID, frame: tile.frame ?? TermPlacement.restoredFrame(index: index), z: tile.z, spawn: spawn
            ))
        }
        if terms.isEmpty {
            terms.append(Term(termID: mint(), frame: Placement.termFrame, z: 0, spawn: SpawnRequest()))
        }

        var recordedOwner: [String: String?] = [:]
        for doc in docs { recordedOwner.updateValue(doc.termID, forKey: doc.path) }

        var placed: [Doc] = []
        var dropped: [String] = []
        var scatterSlot = 0
        for tile in parsed.docs {
            guard let recorded = recordedOwner[tile.path] else {
                dropped.append(tile.path)
                continue
            }
            let owner = recorded.flatMap { restoredID[$0] }
            let frame: CGRect
            if let stored = tile.frame {
                frame = stored
            } else {
                frame = Placement.scatterFrame(slot: scatterSlot)
                scatterSlot += 1
            }
            placed.append(Doc(
                path: tile.path, frame: frame, z: tile.z, ownerTermID: owner, attached: tile.attached && owner != nil
            ))
        }
        return Plan(terms: terms, docs: placed, droppedDocPaths: dropped)
    }
}
