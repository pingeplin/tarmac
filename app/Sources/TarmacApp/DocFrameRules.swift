import Foundation
import TarmacKit
import WebKit

/// `DocFrameRule` as WebKit compiled it, once for the app. Compiling is
/// asynchronous, and a doc's page must not load before its web view has the
/// rule: so a web view asks, and is answered when the rule is there — or when
/// it is known there will be none.
@MainActor
final class DocFrameRules {
    static let shared = DocFrameRules()

    private enum State {
        case compiling([(WKContentRuleList?) -> Void])
        case settled(WKContentRuleList?)
    }

    private var state = State.compiling([])

    private init() {
        // A store of its own: the default one is a folder in the user's
        // Library, and the rule is compiled anew at every launch.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tarmac-content-rules")
        guard let store = WKContentRuleListStore(url: folder) else {
            settle(nil)
            return
        }
        store.compileContentRuleList(
            forIdentifier: DocFrameRule.identifier, encodedContentRuleList: DocFrameRule.json
        ) { [weak self] rules, error in
            if let error {
                Log.stderr("doc frame rule refused: \(error)")
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
