// Posts one real wheel gesture at a card of the live dev app (spec 2610.0002),
// and after it, if asked, a move, a press, a drag and a release of the pointer
// (spec 2610.0004).
//
//   swift scripts/qa/wheel-gesture.swift <card id> [--dy <n>] [--dx <n>] [--events <n>]
//         [--lines] [--select] [--no-end] [--at center|<x>,<y>]
//         [--then thumb|thumb:<x>,<y>|<x>,<y>] [--press] [--clicks <n>]
//         [--drag <dx>,<dy>] [--steps <n>] [--step-ms <ms>]
//         [--sample <ms>] [--sample-last <ms>] [--release] [--stay] [--key escape]
//
// It moves the cursor to the card, posts at the HID tap, and puts the cursor
// back: about half a second in which the pointer is not yours. Nothing is
// posted unless the dev app's own window is the top one under the aim.
//
// `--then` reads the snapshot after the wheel and moves the pointer to the
// card's scroll thumb — its middle, or that many points from its top-left —
// or to a point of the body. `--stay` leaves the pointer where it ends up. A
// call that ends with its press held leaves the pointer too, and the next
// call goes on from there: no wheel, no move to its aim. `--key escape` types
// Escape at the app, before any drag: the way to deselect a card with the
// pointer held.

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
    var then: Then?
    var press = false
    var clicks = 1
    var drag: CGPoint?
    var steps = 10
    var stepMs: UInt32 = 16
    var sample: UInt32?
    var sampleLast: UInt32?
    var release = false
    var stay = false
    /// A virtual key code to type before any drag.
    var key: CGKeyCode?
}

/// Where the pointer goes after the wheel.
enum Then {
    /// A point from the thumb's top-left; nil for its middle.
    case thumb(CGPoint?)
    /// A point from the body's top-left.
    case body(CGPoint)
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
    func point(_ text: Substring, _ flag: String) -> CGPoint {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { fail("\(flag) takes <x>,<y>") }
        return CGPoint(x: parts[0], y: parts[1])
    }
    func count(_ flag: String, atLeast least: Int32) -> Int32 {
        let number = whole(flag)
        if number < least { fail("\(flag) takes a number of \(least) or more") }
        return number
    }
    while let argument = rest.popFirst() {
        switch argument {
        case "--dy": options.dy = whole(argument)
        case "--dx": options.dx = whole(argument)
        case "--events": options.events = Int(count(argument, atLeast: 0))
        case "--then":
            let text = value(of: argument)
            if text == "thumb" {
                options.then = .thumb(nil)
            } else if text.hasPrefix("thumb:") {
                options.then = .thumb(point(text.dropFirst(6), argument))
            } else {
                options.then = .body(point(text[...], argument))
            }
        case "--press": options.press = true
        case "--clicks": options.clicks = Int(count(argument, atLeast: 1))
        case "--drag": options.drag = point(value(of: argument)[...], argument)
        case "--steps": options.steps = Int(count(argument, atLeast: 1))
        case "--step-ms": options.stepMs = UInt32(count(argument, atLeast: 0))
        case "--sample": options.sample = UInt32(count(argument, atLeast: 0))
        case "--sample-last": options.sampleLast = UInt32(count(argument, atLeast: 0))
        case "--release": options.release = true
        case "--stay": options.stay = true
        case "--key":
            guard value(of: argument) == "escape" else { fail("--key takes escape") }
            options.key = 53
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
    if options.card.isEmpty {
        fail("usage: wheel-gesture.swift <card id> [--dy n] [--dx n] [--events n] [--lines] [--select] [--no-end] [--at center|x,y] [--then thumb|thumb:x,y|x,y] [--press] [--clicks n] [--drag dx,dy] [--steps n] [--step-ms ms] [--sample ms] [--sample-last ms] [--release] [--stay] [--key escape]")
    }
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

func facts(of card: String, in snapshot: [String: Any]) -> [String: Any]? {
    (snapshot["cards"] as? [[String: Any]])?.first { $0["id"] as? String == card }
}

func rect(_ value: Any?) -> CGRect? {
    guard let fields = value as? [String: Any],
          let x = number(fields["x"]), let y = number(fields["y"]), let w = number(fields["w"]), let h = number(fields["h"])
    else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
}

guard let first = snapshot() else { fail("no app answers on \(socket) (is `make run` up?)") }
guard let card = facts(of: options.card, in: first) else { fail("no card \(options.card) on the active board") }
guard let cardRect = rect(card["screen_rect"]) else { fail("the card has no screen_rect: it is not laid out") }
guard let origin = first["content_origin"] as? [String: Any], let originX = number(origin["x"]), let originY = number(origin["y"])
else { fail("the snapshot has no content_origin: the window is not on a display") }
guard let zoom = number((first["viewport"] as? [String: Any])?["zoom"]) else { fail("the snapshot has no zoom") }

// The body is the card less its border and, under the top one, its header
// (`CardBox.borderWidth`, `CardBox.headerHeight`).
let border = 1 * zoom
let header = 30 * zoom
let body = CGRect(
    x: cardRect.minX + border, y: cardRect.minY + border + header,
    width: cardRect.width - 2 * border, height: cardRect.height - 2 * border - header
)
let inBody = options.at ?? CGPoint(x: body.width / 2, y: body.height / 2)
let aim = CGPoint(x: originX + body.minX + inBody.x, y: originY + body.minY + inBody.y)

let absoluteSocket = URL(fileURLWithPath: socket).standardizedFileURL.path
guard let owner = String(decoding: run("/usr/sbin/lsof", ["-t", absoluteSocket]).output, as: UTF8.self)
    .split(separator: "\n").first.flatMap({ Int32($0) })
else { fail("no process owns \(absoluteSocket)") }

/// A press an earlier call left held: the file holds how far below the
/// thumb's top it landed.
let heldFile = URL(fileURLWithPath: absoluteSocket).deletingLastPathComponent().appendingPathComponent("wheel-gesture-held")
var heldGrab = (try? String(contentsOf: heldFile, encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
// A call that was cut short can leave the file with no button down.
if heldGrab != nil, !CGEventSource.buttonState(.combinedSessionState, button: .left) {
    try? FileManager.default.removeItem(at: heldFile)
    heldGrab = nil
}
let held = heldGrab != nil

if options.press, held { fail("a press is already held: go on with --drag, or end it with --release") }
if options.drag != nil, !options.press, !held { fail("--drag needs --press, or a press an earlier call left held") }
if options.release, !options.press, !held { fail("--release needs --press, or a press an earlier call left held") }

guard let cursor = CGEvent(source: nil)?.location else { fail("could not read the cursor") }
let start = held ? cursor : aim

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let top = windows.first { window in
    guard (window[kCGWindowLayer as String] as? Int) == 0,
          let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
          let wx = bounds["X"], let wy = bounds["Y"], let ww = bounds["Width"], let wh = bounds["Height"]
    else { return false }
    return CGRect(x: wx, y: wy, width: ww, height: wh).contains(start)
}
guard (top?[kCGWindowOwnerPID as String] as? Int32) == owner else {
    fail("the dev app's window is not the top one at \(Int(start.x)),\(Int(start.y)): bring it forward, or the card into it")
}

// MARK: - Posting

func pause(ms: UInt32) { usleep(ms * 1000) }

func move(to point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func button(_ type: CGEventType, at point: CGPoint, clickState: Int = 1) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    event?.post(tap: .cghidEventTap)
}

/// The card's scroll facts now: its thumb on the display, and its offset.
func scrollNow() -> (thumb: CGRect?, offset: CGFloat?) {
    guard let snapshot = snapshot(), let scroll = facts(of: options.card, in: snapshot)?["scroll"] as? [String: Any]
    else { return (nil, nil) }
    return (rect(scroll["thumb"]).map { $0.offsetBy(dx: originX, dy: originY) }, number(scroll["offset"]))
}

var pointer = start
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

if !held {
    move(to: aim)
    pause(ms: 150)

    if options.select {
        // Click state 1: a double click would borrow the card.
        button(.leftMouseDown, at: aim)
        pause(ms: 40)
        button(.leftMouseUp, at: aim)
        pause(ms: 40)
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

    for index in 0..<options.events {
        if options.lines {
            wheel(dx: options.dx, dy: options.dy, phase: nil, named: "none")
        } else {
            wheel(dx: options.dx, dy: options.dy, phase: index == 0 ? 1 : 2, named: index == 0 ? "began" : "changed")
        }
    }
    if !options.lines, options.end, options.events > 0 { wheel(dx: 0, dy: 0, phase: 4, named: "ended") }

    if let then = options.then {
        // The wheel's report, and the layout it brings, come first.
        pause(ms: 80)
        switch then {
        case .thumb(let from):
            guard let thumb = scrollNow().thumb else {
                move(to: cursor)
                fail("the card has no scroll thumb laid out")
            }
            pointer = from.map { CGPoint(x: thumb.minX + $0.x, y: thumb.minY + $0.y) } ?? CGPoint(x: thumb.midX, y: thumb.midY)
        case .body(let from):
            pointer = CGPoint(x: originX + body.minX + from.x, y: originY + body.minY + from.y)
        }
        move(to: pointer)
        pause(ms: 80)
    }
}

// How far below the thumb's top the press lands: what a sample is read against.
var grab = heldGrab.map { CGFloat($0) } ?? 0
var down = held

if options.press {
    grab = scrollNow().thumb.map { pointer.y - $0.minY } ?? 0
    if options.drag == nil, options.release {
        for click in 1...options.clicks {
            button(.leftMouseDown, at: pointer, clickState: click)
            pause(ms: 40)
            button(.leftMouseUp, at: pointer, clickState: click)
            if click < options.clicks { pause(ms: 60) }
        }
    } else {
        button(.leftMouseDown, at: pointer)
        pause(ms: 40)
        down = true
    }
}

if let key = options.key {
    for down in [true, false] {
        CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)?.post(tap: .cghidEventTap)
        pause(ms: 40)
    }
}

var samples: [[String: Any]] = []

func sample(step: Int, after ms: UInt32) {
    pause(ms: ms)
    let asked = Date()
    let now = scrollNow()
    var fields: [String: Any] = [
        "step": step,
        "pointer_y": pointer.y - originY,
        "grab": grab,
        "read_ms": (Date().timeIntervalSince(asked) * 1000).rounded(),
    ]
    if let thumb = now.thumb {
        fields["thumb_y"] = thumb.minY - originY
        fields["thumb_h"] = thumb.height
        fields["off_by"] = thumb.minY - (pointer.y - grab)
    }
    if let offset = now.offset { fields["offset"] = offset }
    samples.append(fields)
}

if let drag = options.drag {
    let from = pointer
    for step in 1...options.steps {
        let share = CGFloat(step) / CGFloat(options.steps)
        pointer = CGPoint(x: from.x + drag.x * share, y: from.y + drag.y * share)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: pointer, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        pause(ms: options.stepMs)
        if let after = options.sample { sample(step: step, after: after) }
    }
    if let after = options.sampleLast { sample(step: options.steps, after: after) }
}

if down, options.release {
    button(.leftMouseUp, at: pointer)
    try? FileManager.default.removeItem(at: heldFile)
    down = false
} else if down {
    do {
        try "\(grab)".write(to: heldFile, atomically: true, encoding: .utf8)
    } catch {
        button(.leftMouseUp, at: pointer)
        fail("could not note the held press in \(heldFile.path): released it")
    }
}

if !down, !options.stay {
    pause(ms: 200)
    move(to: cursor)
}

var report: [String: Any] = [
    "card": options.card,
    "point": ["x": aim.x, "y": aim.y],
    "selected": options.select,
    "units": options.lines ? "lines" : "points",
    "events": posted,
]
if options.then != nil || options.press || options.drag != nil || held {
    report["pointer"] = ["x": pointer.x - originX, "y": pointer.y - originY]
    report["held"] = down
}
if !samples.isEmpty { report["samples"] = samples }
if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
    print(String(decoding: data, as: UTF8.self))
}
