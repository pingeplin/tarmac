import CoreGraphics
import Foundation

/// 2611.0016: where a daemon `term_new` puts its terminal card, or why it
/// cannot. The card is placed as a ⌘T one is, anchored on its owner.
public enum TermNewPlan {
    public struct Request: Equatable, Sendable {
        public var reqID: UInt64
        public var cmd: String
        public var cwd: String
        public var ownerTermID: String?
        public var boardID: String

        public init(reqID: UInt64, cmd: String, cwd: String, ownerTermID: String?, boardID: String) {
            self.reqID = reqID
            self.cmd = cmd
            self.cwd = cwd
            self.ownerTermID = ownerTermID
            self.boardID = boardID
        }
    }

    public struct Board: Sendable {
        public var built: Bool
        public var restored: Bool
        public var ownerFrame: CGRect?
        public var primeFrame: CGRect?
        public var existing: [CGRect]
        public var zs: [Int]

        public init(built: Bool, restored: Bool, ownerFrame: CGRect?, primeFrame: CGRect?, existing: [CGRect], zs: [Int]) {
            self.built = built
            self.restored = restored
            self.ownerFrame = ownerFrame
            self.primeFrame = primeFrame
            self.existing = existing
            self.zs = zs
        }
    }

    public struct Place: Equatable, Sendable {
        public var frame: CGRect
        public var z: Int
        /// Held for this app run only (D7).
        public var owner: String?
        public var spawn: SpawnRequest
        var cmd: String

        /// D8, D11: not the user's key, so it drops no report or resume record.
        public func input(termID: String) -> Message {
            .input(termID: termID, bytes: Data((cmd + "\r").utf8), typed: false, hold: true)
        }
    }

    public enum Decision: Equatable, Sendable {
        case place(Place)
        case refuse(String)
    }

    public static func notReady(_ boardID: String) -> String {
        "board \(boardID) is not ready in the app; show it, then retry"
    }

    /// D5: a board is spawned on only once it is built and restored on this
    /// connection; a spawn held for either would leave the cli waiting.
    public static func plan(_ request: Request, on board: Board) -> Decision {
        guard board.built, board.restored else {
            return .refuse(notReady(request.boardID))
        }
        let owner = board.ownerFrame.flatMap { _ in request.ownerTermID }
        return .place(Place(
            frame: TermPlacement.newTerminalFrame(prime: board.ownerFrame ?? board.primeFrame, existing: board.existing),
            z: ZOrder.raised(above: board.zs),
            owner: owner,
            spawn: SpawnRequest(cwd: request.cwd),
            cmd: request.cmd
        ))
    }
}
