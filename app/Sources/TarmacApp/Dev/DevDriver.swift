#if DEBUG
import AppKit
import TarmacKit

/// The in-app QA driver's endpoint (spec 2609.0015, issue #166; parity rows
/// Q1–Q7): a second Unix socket the APP owns, so `tarmac dev` can drive and
/// read the cockpit without a keyboard. Debug builds only — the same predicate
/// as the channel mapping (`ChannelPaths.Channel.build`), so availability and
/// channel cannot disagree.
///
/// Socket I/O blocks a thread of its own; every verb runs on the main actor.
/// The thread serves one connection at a time and waits for each answer
/// (`DevRelay`), so every reply describes the state its own verb produced.
@MainActor
final class DevDriver {
    private let relay = DevRelay()
    private var socket: DevSocket?

    /// Binds the endpoint and serves it until the app exits. A refused claim —
    /// a live sibling worktree, a path too long for a socket — is logged and
    /// the app runs without a driver.
    func start(_ verbs: DevVerbs) {
        let environment = ProcessInfo.processInfo.environment
        let path = ChannelPaths.devSocketPath(
            override: environment["TARMAC_DEV_SOCKET"], home: ChannelPaths.home(env: environment), channel: .build
        )
        switch DevSocket.claim(path: path) {
        case .failure(.liveOwner):
            log("a dev driver is already listening on \(path) — not starting a second one")
        case .failure(.pathTooLong):
            log("dev driver disabled: \(ConnectionStatus.socketPathTooLong(path))")
        case .failure(.system(let code)):
            log("dev driver disabled: \(String(cString: strerror(code))) on \(path)")
        case .success(let socket):
            self.socket = socket
            relay.attach { request, completion in
                Task { @MainActor in completion(await verbs.answer(request)) }
            }
            Thread.detachNewThread { [relay] in
                while let connection = socket.accept() {
                    DevSocket.serve(connection, answer: relay.answer)
                }
            }
            log("dev driver listening on \(path)")
        }
    }

    func stop() {
        socket?.close()
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data("tarmac: \(line)\n".utf8))
    }
}
#endif
