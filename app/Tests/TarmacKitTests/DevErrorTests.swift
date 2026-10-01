import XCTest
@testable import TarmacKit

/// The QA driver's failure bodies (spec 2609.0015, parity row Q7): JSON
/// `{error: <code>, message, …extra}` under one closed list of codes.
final class DevErrorTests: XCTestCase {
    /// Q7's list, spelled out: `scripts/qa/` and the CLI branch on these strings.
    func testTheCodesAreExactlyTheWireList() {
        XCTAssertEqual(DevError.Code.allCases.map(\.rawValue), [
            "app_not_ready", "app_unresponsive", "driver_threw", "unsupported_verb", "bad_request",
            "no_such_card", "not_focused", "unsupported_card_kind", "card_hidden",
            "bad_expr", "timeout", "unsupported_combo", "bad_combo", "empty_buffer",
            "not_retargeted", "not_key",
        ])
    }

    func testABodyIsTheCodeTheMessageAndNothingElse() {
        XCTAssertEqual(
            DevError(.appNotReady, "no board yet").body,
            ["error": "app_not_ready", "message": "no board yet"]
        )
    }

    func testExtraFieldsRideBesideTheCodeAndMessage() {
        XCTAssertEqual(
            DevError(.noSuchCard, "nope", extra: ["card": "t-9"]).body,
            ["error": "no_such_card", "message": "nope", "card": "t-9"]
        )
    }

    /// An extra named `error` must not relabel the failure: the code is what the
    /// caller branches on.
    func testExtraFieldsCannotReplaceTheCodeOrTheMessage() {
        let body = DevError(.badCombo, "real", extra: ["error": "timeout", "message": "fake"]).body
        XCTAssertEqual(body, ["error": "bad_combo", "message": "real"])
    }

    func testTheReplyIsNotOkAndCarriesTheBodyAsJSONText() {
        let reply = DevError(.notFocused, "focus first", extra: ["card": "t-1"]).reply
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.body, #"{"card":"t-1","error":"not_focused","message":"focus first"}"#)
    }

    // MARK: - snapshot --until

    /// `smoke.mjs` D9(b) reads `error`, `timeout_ms` and `snapshot.viewport` off
    /// this body, and `lib.mjs`'s `waitFor` reads the final snapshot's tail.
    func testATimeoutCarriesTheExpressionTheBudgetAndTheFinalSnapshot() {
        let snapshot: JSONValue = ["v": 1, "viewport": ["zoom": 1]]
        let error = DevError.timeout(expression: "viewport.zoom == 99", timeoutMs: 300, snapshot: snapshot)
        XCTAssertEqual(error.body, [
            "error": "timeout",
            "message": "`viewport.zoom == 99` did not hold within 300ms",
            "expr": "viewport.zoom == 99",
            "timeout_ms": 300,
            "snapshot": snapshot,
        ])
    }

    func testAMalformedExpressionIsBadExprWithTheParseErrorAsItsMessage() {
        let error = DevError.badExpression(DevUntil.ParseError("missing path"), source: " == 1")
        XCTAssertEqual(error.body, ["error": "bad_expr", "message": "missing path", "expr": " == 1"])
    }
}
