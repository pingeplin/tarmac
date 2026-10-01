import Foundation

/// Which PTY bytes a freshly mounted terminal card may show, and when (issue
/// #41). A mount asks the daemon for that terminal's scrollback ring; until the
/// answer lands, live output is held instead of shown, so the ring reaches the
/// card before anything produced since.
///
/// Owns no clock and sends nothing: the caller sends the `scrollback_request`
/// after `attach`, and calls `expire` with the generation `attach` returned once
/// `awaitTimeoutMs` has passed.
public struct ScrollbackGate {
    /// Held bytes per terminal — the daemon's own ring size.
    public static let bufferCapBytes = 256 * 1024
    /// How long a card waits for its `scrollback` before showing live output
    /// instead. A daemon built before the request existed never answers.
    public static let awaitTimeoutMs = 2000

    private let capBytes: Int
    /// Terminals whose request is outstanding, by the generation of the attach
    /// that sent it. The generation is what lets a deadline recognise that the
    /// mount it was armed for is already gone.
    private var awaiting: [String: UInt64] = [:]
    private var held: [String: [Data]] = [:]
    private var lastGeneration: UInt64 = 0

    public init(capBytes: Int = ScrollbackGate.bufferCapBytes) {
        self.capBytes = capBytes
    }

    public func isAwaiting(_ termID: String) -> Bool {
        awaiting[termID] != nil
    }

    func heldBytes(_ termID: String) -> Int {
        held[termID, default: []].reduce(0) { $0 + $1.count }
    }

    /// A terminal card mounted. Returns the generation its deadline must carry.
    public mutating func attach(_ termID: String) -> UInt64 {
        lastGeneration += 1
        awaiting[termID] = lastGeneration
        return lastGeneration
    }

    /// One `output` chunk: the bytes to show now, or nil while they are held.
    public mutating func output(_ termID: String, _ bytes: Data) -> Data? {
        guard isAwaiting(termID) else { return bytes }
        hold(bytes, for: termID)
        return nil
    }

    /// The daemon's answer: the ring to show, or nil for a terminal that is not
    /// awaiting (a second reply, a card removed mid-request, a request that
    /// already timed out).
    ///
    /// What was held is discarded, not shown: it was already in the daemon's
    /// snapshot, and everything produced after the snapshot arrives after this
    /// reply on the same FIFO socket.
    public mutating func scrollback(_ termID: String, _ bytes: Data) -> Data? {
        guard awaiting.removeValue(forKey: termID) != nil else { return nil }
        held[termID] = nil
        return bytes
    }

    /// No reply is coming: the held chunks to show, oldest first, or nil when
    /// `generation` is not the outstanding attach — the card was answered,
    /// removed, or remounted, and a remount's own deadline still stands.
    public mutating func expire(_ termID: String, generation: UInt64) -> [Data]? {
        guard awaiting[termID] == generation else { return nil }
        awaiting[termID] = nil
        return held.removeValue(forKey: termID) ?? []
    }

    /// A card was removed for good.
    public mutating func forget(_ termID: String) {
        awaiting[termID] = nil
        held[termID] = nil
    }

    /// The socket died, so no outstanding request will be answered. Returns what
    /// each terminal was holding, oldest first.
    public mutating func clearAwaiting() -> [String: [Data]] {
        awaiting = [:]
        defer { held = [:] }
        return held
    }

    /// Keeps the most recent `capBytes`: oldest chunks go first, and a chunk
    /// larger than the cap is cut down to its tail.
    private mutating func hold(_ bytes: Data, for termID: String) {
        guard !bytes.isEmpty else { return }
        let chunk = bytes.count > capBytes ? Data(bytes.suffix(capBytes)) : bytes
        var chunks = held[termID, default: []]
        var total = chunks.reduce(0) { $0 + $1.count }
        while total + chunk.count > capBytes, !chunks.isEmpty {
            total -= chunks.removeFirst().count
        }
        chunks.append(chunk)
        held[termID] = chunks
    }
}
