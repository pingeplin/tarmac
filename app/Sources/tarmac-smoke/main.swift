import Foundation
import TarmacKit

// Cross-language integration proof: drives a real tarmacd over the socket and
// asserts the M0 contract end to end. Prints PASS/FAIL per check; exits nonzero
// on any failure.

final class Inbox: @unchecked Sendable {
    private let cond = NSCondition()
    private var queue: [Message] = []
    private var closedReason: String?

    func push(_ message: Message) {
        cond.lock()
        queue.append(message)
        cond.signal()
        cond.unlock()
    }

    func closed(_ reason: String) {
        cond.lock()
        closedReason = reason
        cond.signal()
        cond.unlock()
    }

    func next(timeout: TimeInterval) -> Message? {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        defer { cond.unlock() }
        while queue.isEmpty {
            if closedReason != nil { return nil }
            if !cond.wait(until: deadline) { return nil }
        }
        return queue.removeFirst()
    }
}

@MainActor
final class Smoke {
    private let inbox = Inbox()
    private var failures = 0

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("PASS \(name)")
        } else {
            failures += 1
            print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    /// Pops messages (skipping non-matching ones) until `extract` returns a
    /// value or the timeout elapses.
    private func waitFor<T>(_ timeout: TimeInterval, _ extract: (Message) -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            guard let message = inbox.next(timeout: remaining) else { return nil }
            if let value = extract(message) { return value }
        }
    }

    func run() -> Int32 {
        let client = DaemonClient(deliveryQueue: DispatchQueue(label: "tarmac.smoke.delivery"))
        let inbox = self.inbox
        client.onMessage = { inbox.push($0) }
        client.onDisconnect = { inbox.closed($0) }

        do {
            try client.connect()
            check("connect + hello sent (\(client.socketPath))", true)
        } catch {
            check("connect + hello sent", false, "\(error)")
            print("RESULT: FAIL (1 failure)")
            return 1
        }

        let gotHelloOK = waitFor(5) { if case .helloOK = $0 { return true } else { return nil } } ?? false
        check("hello_ok received", gotHelloOK)

        // 1. Spawn a term running /bin/echo and assert output then exit.
        let termID = UUID().uuidString
        client.spawnTerm(termID: termID, cols: 80, rows: 24, cwd: nil, cmd: ["/bin/echo", "tarmac-smoke-ok"])
        var outputBytes = Data()
        var sawOutputBeforeExit = false
        let exitResult: Int?? = waitFor(8) { message in
            switch message {
            case .output(let id, let bytes) where id == termID:
                outputBytes.append(bytes)
                return nil
            case .exit(let id, let code) where id == termID:
                sawOutputBeforeExit = !outputBytes.isEmpty
                return .some(code)
            default:
                return nil
            }
        }
        let outputText = String(decoding: outputBytes, as: UTF8.self)
        check(
            "output frame with echoed marker",
            sawOutputBeforeExit && outputText.contains("tarmac-smoke-ok"),
            "got \(outputBytes.count) output bytes: \(outputText.debugDescription)"
        )
        check("exit frame received", exitResult != nil, "no exit frame within 8 s")

        // 2. Open a temp markdown doc and assert doc_opened.
        let docURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tarmac-smoke-\(UUID().uuidString).md")
        // The protocol requires absolute canonical paths (NSTemporaryDirectory lives
        // under the /var -> /private/var symlink).
        do {
            try "# tarmac smoke\n\nhello from tarmac-smoke\n".write(to: docURL, atomically: true, encoding: .utf8)
        } catch {
            check("temp doc created", false, "\(error)")
            print("RESULT: FAIL (\(failures) failures)")
            return 1
        }
        // realpath, not URL.resolvingSymlinksInPath(): the latter strips /private
        // (so /var/... stays /var/...), which is not the canonical path the
        // protocol requires and not what the daemon will report back.
        let canonical: String
        if let resolved = realpath(docURL.path, nil) {
            canonical = String(cString: resolved)
            free(resolved)
        } else {
            canonical = docURL.path
        }
        defer { try? FileManager.default.removeItem(atPath: canonical) }

        client.open(path: canonical)
        let openedVia: String? = waitFor(5) {
            if case .docOpened(let path, let via) = $0, path == canonical { return via } else { return nil }
        }
        check("doc_opened received", openedVia != nil, "no doc_opened for \(canonical) within 5 s")
        if let openedVia {
            check("doc_opened via == \"user\" (app-session open)", openedVia == "user", "got via \(openedVia.debugDescription)")
        }

        // 3. Append to the doc and assert a file_event.
        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: canonical))
            handle.seekToEndOfFile()
            handle.write(Data("\nappended by tarmac-smoke\n".utf8))
            try handle.close()
        } catch {
            check("append to doc", false, "\(error)")
        }
        let mtime: UInt64? = waitFor(5) {
            if case .fileEvent(let path, let mtimeMs) = $0, path == canonical { return mtimeMs } else { return nil }
        }
        check("file_event received", mtime != nil, "no file_event for \(canonical) within 5 s")
        if let mtime {
            check("file_event mtime_ms is sane", mtime > 1_600_000_000_000, "mtime_ms \(mtime)")
        }

        client.close()
        print(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL (\(failures) failure\(failures == 1 ? "" : "s"))")
        return failures == 0 ? 0 : 1
    }
}

exit(Smoke().run())
