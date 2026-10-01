import XCTest
@testable import TarmacKit

/// The bounded hand-off between the driver's socket thread and the app (spec
/// 2609.0015, #166; parity rows Q6–Q7) — `DevDriver::dispatch` in
/// `desktop/src-tauri/src/dev_driver.rs`, S70 and S72.
final class DevRelayTests: XCTestCase {
    /// What the app was handed, and the completions it has not called yet.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [DevRequest] = []
        private var completions: [@Sendable (DevReply) -> Void] = []

        var seen: [DevRequest] { lock.withLock { requests } }

        func record(_ request: DevRequest, _ completion: @escaping @Sendable (DevReply) -> Void) -> Int {
            lock.withLock {
                requests.append(request)
                completions.append(completion)
                return completions.count
            }
        }

        func complete(_ index: Int, _ body: String) {
            lock.withLock { completions[index] }(DevReply(ok: true, body: body))
        }
    }

    private func code(_ reply: DevReply) -> String? {
        guard !reply.ok, let body = try? JSONSerialization.jsonObject(with: Data(reply.body.utf8)) else { return nil }
        return (body as? [String: Any])?["error"] as? String
    }

    private func elapsedMs(_ work: () -> Void) -> Int {
        let started = DispatchTime.now().uptimeNanoseconds
        work()
        return Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }

    // MARK: - the bound

    /// The three deadlines nest — the verb's own budget, the app at `+2000`,
    /// the CLI at `+3000` — so the innermost one always fires.
    func testS70TheWaitIsTheRequestsBudgetPlusTwoSeconds() {
        XCTAssertEqual(DevRelay.waitMs(for: .snapshot(until: nil, timeoutMs: 10_000)), 12_000)
        XCTAssertEqual(DevRelay.waitMs(for: .press(combo: "cmd+q", holdMs: 9_000, ageMs: nil, busyMs: 1_000)), 3_000)
        XCTAssertEqual(DevRelay.waitMs(for: .snapshot(until: nil, timeoutMs: nil)), 2_000)
        XCTAssertEqual(DevRelay.waitMs(for: .focus(card: nil)), 2_000)
        XCTAssertEqual(DevRelay.waitMs(for: .zoom(z: 1), slackMs: 40), 40)
    }

    // MARK: - not ready, not known

    func testS70ARequestBeforeTheAppAttachesIsAnsweredAtOnce() {
        let relay = DevRelay()
        var reply = DevReply(ok: true, body: "")
        XCTAssertLessThan(elapsedMs { reply = relay.answer(.zoom(z: 1)) }, 1_000)
        XCTAssertEqual(code(reply), "app_not_ready")
    }

    /// Answered from the verb alone: asking the app would only produce a second
    /// answer to the same question.
    func testAnUnknownVerbIsRefusedWithoutAskingTheApp() {
        let detached = DevRelay()
        XCTAssertEqual(code(detached.answer(.unknown(type: "teleport"))), "unsupported_verb")

        let recorder = Recorder()
        let attached = DevRelay()
        attached.attach { request, completion in _ = recorder.record(request, completion) }
        let reply = attached.answer(.unknown(type: "teleport"))
        XCTAssertEqual(code(reply), "unsupported_verb")
        XCTAssertTrue(reply.body.contains("teleport"), reply.body)
        XCTAssertEqual(recorder.seen, [])
    }

    // MARK: - answers

    func testTheAppsAnswerIsTheReply() {
        let relay = DevRelay()
        relay.attach { request, completion in
            XCTAssertEqual(request, .zoom(z: 0.5))
            completion(DevReply(ok: true, body: #"{"zoom":0.5}"#))
        }
        XCTAssertEqual(relay.answer(.zoom(z: 0.5)), DevReply(ok: true, body: #"{"zoom":0.5}"#))
    }

    func testAnAnswerGivenLaterFromAnotherThreadIsTheReply() {
        let relay = DevRelay()
        relay.attach { _, completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) {
                completion(DevReply(ok: false, body: "late but in time"))
            }
        }
        XCTAssertEqual(relay.answer(.focus(card: nil)), DevReply(ok: false, body: "late but in time"))
    }

    func testS70ASilentAppIsGivenUpOnAtTheBound() {
        let recorder = Recorder()
        let relay = DevRelay(slackMs: 60)
        relay.attach { request, completion in _ = recorder.record(request, completion) }

        var reply = DevReply(ok: true, body: "")
        let bare = elapsedMs { reply = relay.answer(.focus(card: nil)) }
        XCTAssertEqual(code(reply), "app_unresponsive")
        XCTAssertGreaterThanOrEqual(bare, 60)

        let budgeted = elapsedMs { reply = relay.answer(.snapshot(until: "viewport.zoom == 9", timeoutMs: 150)) }
        XCTAssertEqual(code(reply), "app_unresponsive")
        XCTAssertGreaterThanOrEqual(budgeted, 210)
        XCTAssertEqual(recorder.seen.count, 2)
    }

    /// S72 — a late answer to one request must never be handed to another.
    func testAnAnswerThatArrivesAfterTheBoundReachesNoLaterRequest() {
        let recorder = Recorder()
        let relay = DevRelay(slackMs: 40)
        relay.attach { request, completion in
            let count = recorder.record(request, completion)
            guard count == 2 else { return }
            recorder.complete(0, "stale")
            recorder.complete(1, "mine")
            recorder.complete(1, "again")
        }
        XCTAssertEqual(code(relay.answer(.zoom(z: 1))), "app_unresponsive")
        XCTAssertEqual(relay.answer(.zoom(z: 2)), DevReply(ok: true, body: "mine"))
    }
}
