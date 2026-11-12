import Foundation

/// `tarmac dev board` (#315): when the wait answers. A switch changes the app's
/// `activeBoardID` at once, but the board is on screen only when `switching`
/// ends, so a snapshot read before then would show the leaving board's cards.
public struct DevBoardWait: Equatable, Sendable {
    public enum Goal: Equatable, Sendable {
        /// A switch to this board, or the answer for it already being active.
        case board(String)
        /// A create: the daemon names the new board, so only "not the old one" is known.
        case otherThan(String)
    }

    public let goal: Goal
    public let timeoutMs: Int

    public init(goal: Goal, timeoutMs: Int = DevRequest.boardWaitMs) {
        self.goal = goal
        self.timeoutMs = timeoutMs
    }

    public func step(activeBoardID: String, switching: Bool, elapsedMs: Int) -> DevSnapshotWait.Step {
        if !switching, isReached(by: activeBoardID) { return .reply(Self.reply(boardID: activeBoardID)) }
        guard elapsedMs >= timeoutMs else { return .pollAgain }
        return .reply(timeoutError(activeBoardID: activeBoardID, switching: switching).reply)
    }

    public static func reply(boardID: String) -> DevReply {
        DevReply(ok: true, body: JSONValue.object(["board_id": .string(boardID)]).jsonString)
    }

    private func isReached(by activeBoardID: String) -> Bool {
        switch goal {
        case .board(let id): activeBoardID == id
        case .otherThan(let id): activeBoardID != id
        }
    }

    private func timeoutError(activeBoardID: String, switching: Bool) -> DevError {
        let what: String
        switch goal {
        case .board(let id): what = "board `\(id)` was not active"
        case .otherThan: what = "no new board was active"
        }
        return DevError(
            .timeout, "\(what) within \(timeoutMs)ms",
            extra: ["board_id": .string(activeBoardID), "timeout_ms": .number(Double(timeoutMs)), "switching": .bool(switching)]
        )
    }
}
