import Foundation
import TarmacKit
import WebKit

/// A content rule as WebKit compiled it, once for the app. Compiling is
/// asynchronous, and a page must not load before its web view has the rule:
/// so a web view asks, and is answered when the rule is there — or when it
/// is known there will be none.
@MainActor
final class ContentRules {
    /// The rule a markdown doc's frames load under.
    static let docFrames = ContentRules(identifier: DocFrameRule.identifier, json: DocFrameRule.json)
    /// The rule an HTML card's web view loads under.
    static let cardNetwork = ContentRules(identifier: CardNetworkRule.identifier, json: CardNetworkRule.json)

    // A store of its own: the default one is a folder in the user's
    // Library, and a rule is compiled anew at every launch.
    private static let store = WKContentRuleListStore(
        url: FileManager.default.temporaryDirectory.appendingPathComponent("tarmac-content-rules")
    )

    private enum State {
        case compiling([(WKContentRuleList?) -> Void])
        case settled(WKContentRuleList?)
    }

    private var state = State.compiling([])

    private init(identifier: String, json: String) {
        guard let store = Self.store else {
            settle(nil)
            return
        }
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { [weak self] rules, error in
            if let error {
                Log.stderr("content rule \(identifier) refused: \(error)")
            }
            self?.settle(rules)
        }
    }

    /// Calls `then` with the compiled rule, or with nil if WebKit refused it.
    func whenSettled(_ then: @escaping (WKContentRuleList?) -> Void) {
        switch state {
        case .compiling(let waiting): state = .compiling(waiting + [then])
        case .settled(let rules): then(rules)
        }
    }

    private func settle(_ rules: WKContentRuleList?) {
        guard case .compiling(let waiting) = state else { return }
        state = .settled(rules)
        waiting.forEach { $0(rules) }
    }
}
