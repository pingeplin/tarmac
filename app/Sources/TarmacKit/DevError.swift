import Foundation

/// A QA-driver failure (spec 2609.0015, issue #166). Every refusal the app
/// answers is JSON `{error: <code>, message, …extra}`, so a scenario branches on
/// the code instead of string-matching a sentence. The codes are the contract
/// with `scripts/qa/` and the CLI; a message is for whoever reads stderr and may
/// be reworded freely.
public struct DevError: Error, Equatable, Sendable {
    public enum Code: String, CaseIterable, Sendable {
        case appNotReady = "app_not_ready"
        case appUnresponsive = "app_unresponsive"
        case driverThrew = "driver_threw"
        case unsupportedVerb = "unsupported_verb"
        case badRequest = "bad_request"
        case noSuchCard = "no_such_card"
        case notFocused = "not_focused"
        case unsupportedCardKind = "unsupported_card_kind"
        case cardHidden = "card_hidden"
        case badExpr = "bad_expr"
        case timeout
        case unsupportedCombo = "unsupported_combo"
        case badCombo = "bad_combo"
        case emptyBuffer = "empty_buffer"
        case notRetargeted = "not_retargeted"
        case notKey = "not_key"
    }

    public var code: Code
    public var message: String
    public var extra: [String: JSONValue]

    public init(_ code: Code, _ message: String, extra: [String: JSONValue] = [:]) {
        self.code = code
        self.message = message
        self.extra = extra
    }

    /// `error` and `message` are written last: an extra field of either name
    /// must not relabel the failure the caller branches on.
    public var body: JSONValue {
        var fields = extra
        fields["error"] = .string(code.rawValue)
        fields["message"] = .string(message)
        return .object(fields)
    }

    public var reply: DevReply { DevReply(ok: false, body: body.jsonString) }
}

public extension DevError {
    /// `snapshot --until` ran out its budget. The final snapshot rides along, so
    /// a failed wait shows what the app looked like instead of only that it
    /// never matched.
    static func timeout(expression: String, timeoutMs: Int, snapshot: JSONValue) -> DevError {
        DevError(
            .timeout,
            "`\(expression)` did not hold within \(timeoutMs)ms",
            extra: ["expr": .string(expression), "timeout_ms": .number(Double(timeoutMs)), "snapshot": snapshot]
        )
    }

    static func badExpression(_ error: DevUntil.ParseError, source: String) -> DevError {
        DevError(.badExpr, error.message, extra: ["expr": .string(source)])
    }
}
