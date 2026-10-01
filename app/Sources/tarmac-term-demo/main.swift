import AppKit
import TarmacKit
import TarmacTerm

// Dev harness: one TerminalView bound to a daemon PTY, optionally driven by a
// script and snapshotted to a PNG, so the terminal card can be checked on its
// own. Environment:
//   TERM_DEMO_SCRIPT   text typed into the shell once it is up ("\n" allowed)
//   TERM_DEMO_SHOT     PNG path written after TERM_DEMO_WAIT seconds, and again
//                      as <name>-b.png one cursor-blink interval later
//   TERM_DEMO_WAIT     seconds between the script and the snapshot (default 2)
//   TERM_DEMO_QUIT     quit after the snapshot when set
//   TERM_DEMO_SCALE    scale the view like a zoomed board card (default 1)

@MainActor
final class Demo: NSObject, NSApplicationDelegate {
    let client = DaemonClient()
    let termID = BootTerminal.mint()
    var window: NSWindow!
    var terminal: TerminalView!
    let environment = ProcessInfo.processInfo.environment

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scale = environment["TERM_DEMO_SCALE"].flatMap(Double.init) ?? 1
        let size = NSSize(width: 820, height: 500)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: size.width * scale, height: size.height * scale)),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "tarmac-term-demo"
        terminal = try! TerminalView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        terminal.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(terminal)
        if scale != 1 {
            // The board's zoom: frame carries the scale, bounds stay in world units.
            terminal.autoresizingMask = []
            terminal.setBoundsSize(size)
            terminal.layer?.contentsScale = (window.backingScaleFactor) * scale
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        NSApp.activate(ignoringOtherApps: true)
        if let screen = window.screen {
            // Top-left origin, the form `screencapture -R` takes.
            let content = window.convertToScreen(window.contentLayoutRect)
            let top = screen.frame.maxY - content.maxY
            FileHandle.standardError.write(Data(
                "demo: content \(Int(content.minX)),\(Int(top)),\(Int(content.width)),\(Int(content.height))\n".utf8
            ))
        }

        terminal.onInput = { [client, termID] in client.input(termID: termID, bytes: Data($0)) }
        terminal.onResize = { [client, termID] in client.resize(termID: termID, cols: $0, rows: $1) }
        terminal.onTitleChanged = { [weak self] in self?.window.title = $0 ?? "tarmac-term-demo" }
        terminal.onClipboardWrite = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString($0, forType: .string)
        }

        client.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.handle(message) }
        }
        client.onDisconnect = { reason in
            FileHandle.standardError.write(Data("demo: disconnected: \(reason)\n".utf8))
        }
        DispatchQueue.global().async { [client] in
            do { try client.connect() } catch {
                FileHandle.standardError.write(Data("demo: connect failed: \(error)\n".utf8))
            }
        }
    }

    private var spawned = false

    private func handle(_ message: Message) {
        switch message {
        case .helloOK:
            guard !spawned else { return }
            spawned = true
            client.spawnTerm(termID: termID, cols: terminal.cols, rows: terminal.rows, cwd: NSHomeDirectory(), cmd: nil)
            runScript()
        case .output(let id, let bytes) where id == termID:
            terminal.feed(bytes)
        case .exit(let id, _) where id == termID:
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private func runScript() {
        let wait = environment["TERM_DEMO_WAIT"].flatMap(Double.init) ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            if let script = environment["TERM_DEMO_SCRIPT"] {
                terminal.sendText(script.replacingOccurrences(of: "\\n", with: "\r"))
            }
            guard let path = environment["TERM_DEMO_SHOT"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
                snapshot(to: path)
                // A second shot one blink interval later catches the other cursor phase.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                    snapshot(to: path.replacingOccurrences(of: ".png", with: "-b.png"))
                    if environment["TERM_DEMO_QUIT"] != nil {
                        client.termClose(termID: termID)
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    private func snapshot(to path: String) {
        guard let rep = terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds) else { return }
        terminal.cacheDisplay(in: terminal.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("demo: wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))\n".utf8))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Demo()
app.delegate = delegate
app.run()
