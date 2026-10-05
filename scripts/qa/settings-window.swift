// Operates the Settings window of the live dev app with no pointer (spec
// 2610.0005), through the Accessibility API, and posts a click or a wheel at
// a screen point for the one scenario that needs real pointer events.
//
//   swift scripts/qa/settings-window.swift <pid> <verb> ...
//
//   open                     posts ⌘, to the app
//   rows                     prints each row's selected title, and the window's labels
//   pick <row> <title>       row 0, 1, 2 = Terminal, Interface, Document
//   menu <item title>        chooses an item of the app menu, e.g. "Warn Before Quitting (⌘Q)"
//   move <x> <y>             puts the window's top-left there, in global points
//   key <key code>           posts ⌘ and that key to the app: 43 is `,`, 13 `w`, 12 `q`
//   click <x> <y>            a left click at a global point
//   wheel <x> <y> <dy> [ctrl]  eight wheel events at a global point
//
// <pid> is the app's: `lsof -t "$PWD/.dev/tarmac-dev.sock"`. The process that
// runs this needs the Accessibility permission.
//
// After a second window has been shown — so after `open` — the system's
// tiling items in the Window menu (Fill ⌃F, Center ⌃C, Return to Previous
// Size ⌃R) claim those chords when `tarmac dev key` sends them: `key <term>
// ctrl+c` no longer interrupts, and `ctrl+f` resizes the window. A real
// keyboard is not affected. Reading the Window menu through Accessibility
// does the same, so only the app menu is read here. Run `make qa` in an app
// that has not shown the Settings window.
//
// `click` and `wheel` move the cursor there, post at the HID tap, and put the
// cursor back, as `wheel-gesture.swift` does for a card: the two are
// single-file scripts and cannot share code. A wheel that carries only the Control flag leaves Control
// latched in the system's modifier state, and every later wheel then zooms in
// every app: so `ctrl` presses and releases the Control key around the wheel,
// and the script fails if the flag is still set when it ends.

import ApplicationServices
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("settings-window: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, let pid = pid_t(arguments[0]) else { fail("usage: <pid> <verb> ...; see the header") }
let verb = arguments[1], rest = Array(arguments.dropFirst(2))

func number(_ index: Int) -> Double {
    guard rest.indices.contains(index), let value = Double(rest[index]) else { fail("\(verb): argument \(index + 1) is not a number") }
    return value
}

// MARK: - Accessibility

let app = AXUIElementCreateApplication(pid)

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute) ?? "" }
func title(_ element: AXUIElement) -> String { attribute(element, kAXTitleAttribute) ?? "" }
func value(_ element: AXUIElement) -> String { attribute(element, kAXValueAttribute) ?? "" }

func descendants(of element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 12 else { return [] }
    let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
    return children.flatMap { [$0] + descendants(of: $0, depth: depth + 1) }
}

func press(_ element: AXUIElement, _ what: String) {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { fail("\(what): press failed (\(result.rawValue))") }
}

func settingsWindow() -> AXUIElement {
    let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
    guard let window = windows.first(where: { title($0) == "Settings" }) else { fail("the app has no Settings window; run `open`") }
    return window
}

func popUps() -> [AXUIElement] {
    descendants(of: settingsWindow()).filter { role($0) == kAXPopUpButtonRole }
}

/// An item of the app menu, the bar's second: the Apple menu is its first.
func appMenuItem(_ name: String) -> AXUIElement {
    let menus: [AXUIElement] = (attribute(app, kAXMenuBarAttribute) as AXUIElement?)
        .flatMap { attribute($0, kAXChildrenAttribute) } ?? []
    guard menus.count > 1,
        let item = descendants(of: menus[1]).first(where: { role($0) == kAXMenuItemRole && title($0) == name })
    else { fail("the app menu has no item titled \(name)") }
    return item
}

func postCommand(_ code: CGKeyCode) {
    let session = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: session, virtualKey: code, keyDown: down)
        event?.flags = .maskCommand
        event?.postToPid(pid)
        usleep(60_000)
    }
}

// MARK: - Pointer

let hid = CGEventSource(stateID: .hidSystemState)

func control(_ down: Bool) {
    let event = CGEvent(keyboardEventSource: hid, virtualKey: 59, keyDown: down)
    event?.flags = down ? .maskControl : []
    event?.post(tap: .cghidEventTap)
    usleep(80_000)
}

/// Runs `body` with the cursor at `point`, then puts the cursor back.
func at(_ point: CGPoint, _ body: () -> Void) {
    let home = CGEvent(source: nil)?.location ?? point
    CGWarpMouseCursorPosition(point)
    usleep(150_000)
    CGEvent(mouseEventSource: hid, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(100_000)
    body()
    usleep(200_000)
    CGWarpMouseCursorPosition(home)
    guard !CGEventSource.flagsState(.hidSystemState).contains(.maskControl) else { fail("Control is still latched") }
}

// MARK: - Verbs

guard AXIsProcessTrusted() else { fail("this process does not have the Accessibility permission") }

switch verb {
case "open":
    postCommand(43)
case "rows":
    let window = settingsWindow(), views = descendants(of: window)
    for (index, popUp) in views.filter({ role($0) == kAXPopUpButtonRole }).enumerated() {
        print("\(index) selected=\(value(popUp))")
    }
    print("labels=\(views.filter { role($0) == kAXStaticTextRole }.map(value))")
    print("resizable=\((attribute(window, "AXGrowArea") as AXUIElement?) != nil)")
case "pick":
    let rows = popUps()
    guard rest.count == 2, let row = Int(rest[0]), rows.indices.contains(row) else { fail("pick <row> <title>") }
    let popUp = rows[row]
    press(popUp, "the pop-up")
    usleep(400_000)
    let items = descendants(of: popUp).filter { role($0) == kAXMenuItemRole }
    guard let item = items.first(where: { title($0) == rest[1] }) else {
        AXUIElementPerformAction(popUp, kAXCancelAction as CFString)
        fail("row \(row) lists \(items.count) entries and none is \(rest[1])")
    }
    press(item, rest[1])
    print("picked \(rest[1]) of \(items.count)")
case "menu":
    guard rest.count == 1 else { fail("menu <item title>") }
    let item = appMenuItem(rest[0])
    press(item, rest[0])
    print("chose \(rest[0]) key=\((attribute(item, kAXMenuItemCmdCharAttribute) as String?) ?? "")")
case "move":
    var point = CGPoint(x: number(0), y: number(1))
    guard let position = AXValueCreate(.cgPoint, &point),
        AXUIElementSetAttributeValue(settingsWindow(), kAXPositionAttribute as CFString, position) == .success
    else { fail("the window did not move") }
case "key":
    guard rest.count == 1, let code = CGKeyCode(rest[0]) else { fail("key <key code>") }
    postCommand(code)
case "click":
    let point = CGPoint(x: number(0), y: number(1))
    at(point) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: hid, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(80_000)
        }
    }
case "wheel":
    let point = CGPoint(x: number(0), y: number(1)), dy = Int32(number(2))
    let withControl = rest.count > 3 && rest[3] == "ctrl"
    at(point) {
        if withControl { control(true) }
        for _ in 0..<8 {
            let event = CGEvent(scrollWheelEvent2Source: hid, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
            if withControl { event?.flags = .maskControl }
            event?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        if withControl { control(false) }
    }
default:
    fail("unknown verb \(verb); see the header")
}
