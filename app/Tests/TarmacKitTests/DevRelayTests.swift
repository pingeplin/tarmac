import XCTest
@testable import TarmacKit

/// The bounded hand-off between the driver's socket thread and the app (spec
/// 2609.0015, #166; parity rows Q6–Q7) — `DevDriver::dispatch` in
/// `desktop/src-tauri/src/dev_driver.rs` (S70, S72) and the one-at-a-time queue
/// in `desktop/src/devDriver.ts`.
final class DevRelayTests: XCTestCase {
    /// What the app was asked, in order, and a gate a verb can be held at.
    private final class App: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var open = false

        var events: [String] { lock.withLock { log } }

        func note(_ event: String) {
            lock.withLock { log.append(event) }
        }

        func openGate() {
            lock.withLock { open = true }
        }

        func gate() async {
            while !lock.withLock({ open }) {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func code(_ reply: DevReply) -> String? {
        guard !reply.ok, let body = try? JSONSerialization.jsonObject(with: Data(reply.body.utf8)) else { return nil }
        return (body as? [String: Any])?["error"] as? String
    }

    private func timed(_ work: () -> DevReply) -> (reply: DevReply, ms: Int) {
        let started = DispatchTime.now().uptimeNanoseconds
        let reply = work()
        return (reply, Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
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

    /// The wait is the bound: no shorter, and neither a multiple of it nor the
    /// default slack in place of this relay's own.
    func testS70ASilentAppIsGivenUpOnAtTheBound() {
        let app = App()
        defer { app.openGate() }
        let relay = DevRelay(slackMs: 200)
        relay.attach { _ in
            await app.gate()
            return DevReply(ok: true, body: "late")
        }
        let bare = timed { relay.answer(.focus(card: nil)) }
        XCTAssertEqual(code(bare.reply), "app_unresponsive")
        XCTAssertGreaterThanOrEqual(bare.ms, 200)
        XCTAssertLessThan(bare.ms, 500)

        let budgeted = timed { relay.answer(.snapshot(until: "viewport.zoom == 9", timeoutMs: 150)) }
        XCTAssertEqual(code(budgeted.reply), "app_unresponsive")
        XCTAssertGreaterThanOrEqual(budgeted.ms, 350)
        XCTAssertLessThan(budgeted.ms, 900)
    }

    // MARK: - not ready, not known

    func testS70ARequestBeforeTheAppAttachesIsAnsweredAtOnce() {
        let answered = timed { DevRelay().answer(.zoom(z: 1)) }
        XCTAssertEqual(code(answered.reply), "app_not_ready")
        XCTAssertLessThan(answered.ms, 1_000)
    }

    /// Answered from the verb alone: asking the app would only produce a second
    /// answer to the same question.
    func testAnUnknownVerbIsRefusedWithoutAskingTheApp() {
        XCTAssertEqual(code(DevRelay().answer(.unknown(type: "teleport"))), "unsupported_verb")

        let app = App()
        let attached = DevRelay()
        attached.attach { request in
            app.note("\(request)")
            return DevReply(ok: true, body: "{}")
        }
        let reply = attached.answer(.unknown(type: "teleport"))
        XCTAssertEqual(code(reply), "unsupported_verb")
        XCTAssertTrue(reply.body.contains("teleport"), reply.body)
        XCTAssertEqual(app.events, [])
    }

    // MARK: - answers

    func testTheAppsAnswerIsTheReply() {
        let relay = DevRelay()
        relay.attach { request in
            XCTAssertEqual(request, .zoom(z: 0.5))
            try? await Task.sleep(for: .milliseconds(20))
            return DevReply(ok: true, body: #"{"zoom":0.5}"#)
        }
        XCTAssertEqual(relay.answer(.zoom(z: 0.5)), DevReply(ok: true, body: #"{"zoom":0.5}"#))
    }

    /// S72 and Q6 — a verb the relay gave up on is still running. Its answer
    /// reaches no later request, and the next verb does not start until it has
    /// finished: two verbs interleaved at their suspension points would each
    /// report a state the other was halfway through changing.
    func testAVerbGivenUpOnFinishesBeforeTheNextStartsAndAnswersNobody() {
        let app = App()
        let relay = DevRelay(slackMs: 100)
        relay.attach { request in
            let name = request == .zoom(z: 1) ? "first" : "second"
            app.note("\(name) starts")
            if name == "first" { await app.gate() }
            app.note("\(name) ends")
            return DevReply(ok: true, body: name)
        }
        XCTAssertEqual(code(relay.answer(.zoom(z: 1))), "app_unresponsive")

        let answered = expectation(description: "the second request is answered")
        let second = Reply()
        Thread.detachNewThread {
            second.set(relay.answer(.snapshot(until: nil, timeoutMs: 20_000)))
            answered.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(app.events, ["first starts"])

        app.openGate()
        wait(for: [answered], timeout: 10)
        XCTAssertEqual(second.value, DevReply(ok: true, body: "second"))
        XCTAssertEqual(app.events, ["first starts", "first ends", "second starts", "second ends"])
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var reply: DevReply?

        var value: DevReply? { lock.withLock { reply } }

        func set(_ reply: DevReply) {
            lock.withLock { self.reply = reply }
        }
    }
}
