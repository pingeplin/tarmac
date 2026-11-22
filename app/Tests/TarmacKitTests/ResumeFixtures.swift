import CoreGraphics
import TarmacKit
import XCTest

extension ResumeOffer {
    /// The offer of `cmd` after `events`. A refused command or an offer that
    /// an event ends fails the test.
    static func fixture(_ cmd: String = "echo HI", after events: [Event] = []) throws -> ResumeOffer {
        try XCTUnwrap(events.reduce(make(cmd: cmd)) { step($0, $1).offer })
    }
}

extension BoardRestore.Term {
    static func fixture(_ id: String, spawn: SpawnRequest?, resume: String? = nil) -> BoardRestore.Term {
        BoardRestore.Term(termID: id, frame: .zero, z: 0, spawn: spawn, resume: resume)
    }
}
