// Posts one real wheel gesture at a card of the live dev app (spec 2610.0002).
//
//   swift scripts/qa/wheel-gesture.swift <card id> [--dy <n>] [--dx <n>] [--events <n>]
//         [--lines] [--select] [--no-end] [--at center|<x>,<y>]
//
// It moves the cursor to the card, posts at the HID tap, and puts the cursor
// back: about half a second in which the pointer is not yours. Nothing is
// posted unless the dev app's own window is the top one under the aim.

import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("wheel-gesture: \(message)\n".utf8))
    exit(1)
}

// MARK: - Arguments

struct Options {
    var card = ""
    var dy: Int32 = -10
    var dx: Int32 = 0
    var events = 10
    var lines = false
    var select = false
    var end = true
    /// A point from the body's top-left, in screen points; nil for its middle.
    var at: CGPoint?
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var rest = arguments[...]
    func value(of flag: String) -> String {
        guard let value = rest.popFirst() else { fail("\(flag) needs a value") }
        return value
    }
    func whole(_ flag: String) -> Int32 {
        guard let number = Int32(value(of: flag)) else { fail("\(flag) takes a whole number") }
        return number
    }
    while let argument = rest.popFirst() {
        switch argument {
        case "--dy": options.dy = whole(argument)
        case "--dx": options.dx = whole(argument)
        case "--events":
            options.events = Int(whole(argument))
            if options.events < 1 { fail("--events takes a number of 1 or more") }
        case "--lines": options.lines = true
        case "--select": options.select = true
        case "--no-end": options.end = false
        case "--at":
            let text = value(of: argument)
            if text == "center" { break }
            let parts = text.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { fail("--at takes center or <x>,<y>") }
            options.at = CGPoint(x: parts[0], y: parts[1])
        default:
            guard !argument.hasPrefix("--"), options.card.isEmpty else { fail("unknown argument \(argument)") }
            options.card = argument
        }
    }
    if options.card.isEmpty { fail("usage: wheel-gesture.swift <card id> [--dy n] [--dx n] [--events n] [--lines] [--select] [--no-end] [--at center|x,y]") }
    return options
}

// MARK: - The app

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let cli = root.appendingPathComponent("core/target/debug/tarmac").path

func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return (1, Data()) }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, output)
}

func snapshot() -> [String: Any]? {
    let result = run(cli, ["dev", "snapshot", "--timeout", "0"])
    guard result.status == 0 else { return nil }
    return (try? JSONSerialization.jsonObject(with: result.output)) as? [String: Any]
}

func number(_ value: Any?) -> CGFloat? {
    (value as? NSNumber).map { CGFloat(truncating: $0) }
}

// MARK: - The aim

let options = parse(Array(CommandLine.arguments.dropFirst()))

guard let socket = ProcessInfo.processInfo.environment["TARMAC_DEV_SOCKET"], !socket.isEmpty else {
    fail("TARMAC_DEV_SOCKET is not set")
}
guard FileManager.default.isExecutableFile(atPath: cli) else { fail("no debug CLI at \(cli): run `make core`") }
guard let facts = snapshot() else { fail("no app answers on \(socket) (is `make run` up?)") }
guard let card = (facts["cards"] as? [[String: Any]])?.first(where: { $0["id"] as? String == options.card }) else {
    fail("no card \(options.card) on the active board")
}
guard let rect = card["screen_rect"] as? [String: Any],
      let x = number(rect["x"]), let y = number(rect["y"]), let w = number(rect["w"]), let h = number(rect["h"])
else { fail("the card has no screen_rect: it is not laid out") }
guard let origin = facts["content_origin"] as? [String: Any], let originX = number(origin["x"]), let originY = number(origin["y"])
else { fail("the snapshot has no content_origin: the window is not on a display") }
guard let zoom = number((facts["viewport"] as? [String: Any])?["zoom"]) else { fail("the snapshot has no zoom") }

// The body is the card less its border and, under the top one, its header
// (`CardBox.borderWidth`, `CardBox.headerHeight`).
let border = 1 * zoom
let header = 30 * zoom
let body = CGRect(x: x + border, y: y + border + header, width: w - 2 * border, height: h - 2 * border - header)
let inBody = options.at ?? CGPoint(x: body.width / 2, y: body.height / 2)
let aim = CGPoint(x: originX + body.minX + inBody.x, y: originY + body.minY + inBody.y)

let absoluteSocket = URL(fileURLWithPath: socket).standardizedFileURL.path
guard let owner = String(decoding: run("/usr/sbin/lsof", ["-t", absoluteSocket]).output, as: UTF8.self)
    .split(separator: "\n").first.flatMap({ Int32($0) })
else { fail("no process owns \(absoluteSocket)") }

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let top = windows.first { window in
    guard (window[kCGWindowLayer as String] as? Int) == 0,
          let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
          let wx = bounds["X"], let wy = bounds["Y"], let ww = bounds["Width"], let wh = bounds["Height"]
    else { return false }
    return CGRect(x: wx, y: wy, width: ww, height: wh).contains(aim)
}
guard (top?[kCGWindowOwnerPID as String] as? Int32) == owner else {
    fail("the dev app's window is not the top one at \(Int(aim.x)),\(Int(aim.y)): bring it forward, or the card into it")
}

// MARK: - Posting

func pause(ms: UInt32) { usleep(ms * 1000) }

func move(to point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

guard let cursor = CGEvent(source: nil)?.location else { fail("could not read the cursor") }
move(to: aim)
pause(ms: 150)

if options.select {
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        // Click state 1: a double click would borrow the card.
        let click = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: aim, mouseButton: .left)
        click?.setIntegerValueField(.mouseEventClickState, value: 1)
        click?.post(tap: .cghidEventTap)
        pause(ms: 40)
    }
    var selected = false
    for _ in 0..<20 where !selected {
        pause(ms: 50)
        selected = snapshot()?["focused_card"] as? String == options.card
    }
    guard selected else {
        move(to: cursor)
        fail("the click did not select the card: run `tarmac dev focus board` first, so the dev window is key")
    }
}

var posted: [[String: Any]] = []

func wheel(dx: Int32, dy: Int32, phase: Int64?, named name: String) {
    guard let event = CGEvent(
        scrollWheelEvent2Source: nil, units: options.lines ? .line : .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0
    ) else { return }
    if let phase {
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    }
    event.post(tap: .cghidEventTap)
    posted.append(["dx": dx, "dy": dy, "phase": name])
    pause(ms: options.lines ? 120 : 16)
}

for index in 0..<options.events {
    if options.lines {
        wheel(dx: options.dx, dy: options.dy, phase: nil, named: "none")
    } else {
        wheel(dx: options.dx, dy: options.dy, phase: index == 0 ? 1 : 2, named: index == 0 ? "began" : "changed")
    }
}
if !options.lines, options.end { wheel(dx: 0, dy: 0, phase: 4, named: "ended") }

pause(ms: 200)
move(to: cursor)

let report: [String: Any] = [
    "card": options.card,
    "point": ["x": aim.x, "y": aim.y],
    "selected": options.select,
    "units": options.lines ? "lines" : "points",
    "events": posted,
]
if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
    print(String(decoding: data, as: UTF8.self))
}
