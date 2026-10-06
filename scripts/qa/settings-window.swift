// Operates the Settings window of the live dev app with no pointer (specs
// 2610.0005, 2610.0006, 2610.0007, 2610.0008), through the Accessibility API, and posts
// a click or a wheel at a screen point for the one scenario that needs real
// pointer events.
//
//   swift scripts/qa/settings-window.swift <pid> <verb> ...
//
//   open                     posts ⌘, to the app
//   rows                     prints the selected pane, each row's selected title, each size, each theme tile with its value (1 = selected), and the window's labels, with frames
//   pane <title>             selects a sidebar entry: Fonts, Theme
//   theme <title>            presses a tile of the Theme pane: Auto, Light, Dark
//   theme-of <Light|Dark> <title>  prints the themes that appearance's pop-up lists, then chooses one
//   pick <row> <title>       row 0, 1, 2 = Terminal, Interface, Document
//   size <n> <text>          sets a size field's text and confirms it, as Return does; n 0, 1 = Terminal, Document
//   step <n> up|down [count] presses a size's stepper
//   focus <n>                gives a size field the keyboard focus, its text selected
//   type <text>              posts the text to the app as plain keys
//   press <key code>         posts one plain key to the app: 36 is Return, 48 Tab, 53 Escape
//   menu <item title>        chooses an item of the app menu, e.g. "Warn Before Quitting (⌘Q)"
//   move <x> <y>             puts the window's top-left there, in global points
//   key <key code>           posts ⌘ and that key to the app: 43 is `,`, 13 `w`, 12 `q`
//   click <x> <y>            a left click at a global point
//   wheel <x> <y> <dy> [ctrl]  eight wheel events at a global point
//
// `type` posts each character on a key code no layout has, with the
// character in the event: a real digit key goes through the input source,
// and under Zhuyin `20` arrives as `ㄉㄢ`.
//
// `pick`, `size`, `step` and `focus` count the controls of the pane that
// shows: they need the Fonts pane, and `theme` and `theme-of` need the Theme
// pane.
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

func perform(_ action: String, on element: AXUIElement, _ what: String) {
    let result = AXUIElementPerformAction(element, action as CFString)
    guard result == .success else { fail("\(what): \(action) failed (\(result.rawValue))") }
}

func press(_ element: AXUIElement, _ what: String) { perform(kAXPressAction, on: element, what) }

func settingsWindow() -> AXUIElement {
    let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
    guard let window = windows.first(where: { title($0) == "Settings" }) else { fail("the app has no Settings window; run `open`") }
    return window
}

func controls(_ wanted: String) -> [AXUIElement] {
    descendants(of: settingsWindow()).filter { role($0) == wanted }
}

/// A sidebar entry's title: the text of the row's cell.
func paneTitle(_ row: AXUIElement) -> String {
    descendants(of: row).first { role($0) == kAXStaticTextRole }.map(value) ?? ""
}

/// 1 for the selected radio button, 0 for another.
func state(_ element: AXUIElement) -> Int {
    (attribute(element, kAXValueAttribute) as NSNumber?)?.intValue ?? -1
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

func frame(_ element: AXUIElement) -> String {
    var rect = CGRect.zero
    guard let value: AXValue = attribute(element, "AXFrame"), AXValueGetValue(value, .cgRect, &rect) else { return "?" }
    return "\(rect.minX),\(rect.minY) \(rect.width)x\(rect.height)"
}

/// The control of role `wanted` that the verb's first argument counts to.
func control(_ wanted: String, _ what: String) -> AXUIElement {
    let found = controls(wanted)
    guard let index = rest.first.flatMap(Int.init), found.indices.contains(index) else {
        fail("\(verb) <n> ...: the window has \(found.count) \(what)")
    }
    return found[index]
}

/// Opens a pop-up and gives the items of its menu, in their order.
func open(_ popUp: AXUIElement) -> [AXUIElement] {
    press(popUp, "the pop-up")
    usleep(400_000)
    return descendants(of: popUp).filter { role($0) == kAXMenuItemRole }
}

/// Chooses the item with that title in an open pop-up, or closes the menu
/// and fails.
func choose(_ name: String, of items: [AXUIElement], in popUp: AXUIElement, _ what: String) {
    guard let item = items.first(where: { title($0) == name }) else {
        AXUIElementPerformAction(popUp, kAXCancelAction as CFString)
        fail("\(what) lists \(items.count) entries and none is \(name)")
    }
    press(item, name)
    print("picked \(name) of \(items.count)")
}

func post(_ code: CGKeyCode, flags: CGEventFlags = [], character: Character? = nil) {
    let session = CGEventSource(stateID: .combinedSessionState)
    let units = character.map { Array(String($0).utf16) }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: session, virtualKey: code, keyDown: down)
        event?.flags = flags
        if let units { event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
        event?.postToPid(pid)
        usleep(60_000)
    }
}

func postCommand(_ code: CGKeyCode) { post(code, flags: .maskCommand) }

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
    let selected = views.filter { role($0) == kAXRowRole && (attribute($0, kAXSelectedAttribute) as Bool?) == true }
    print("pane=\(selected.map(paneTitle).joined(separator: ","))")
    for tile in views.filter({ role($0) == kAXRadioButtonRole }) {
        print("tile \(title(tile)) value=\(state(tile)) frame=\(frame(tile))")
    }
    for (index, popUp) in views.filter({ role($0) == kAXPopUpButtonRole }).enumerated() {
        print("\(index) selected=\(value(popUp)) frame=\(frame(popUp))")
    }
    for (index, field) in views.filter({ role($0) == kAXTextFieldRole }).enumerated() {
        let label: String = attribute(field, kAXDescriptionAttribute) ?? ""
        print("size \(index) value=\(value(field)) label=\(label) frame=\(frame(field))")
    }
    for stepper in views.filter({ role($0) == kAXIncrementorRole }) { print("stepper frame=\(frame(stepper))") }
    let texts = views.filter { role($0) == kAXStaticTextRole }
    for text in texts { print("label \(value(text)) frame=\(frame(text))") }
    print("labels=\(texts.map(value))")
    print("resizable=\((attribute(window, "AXGrowArea") as AXUIElement?) != nil)")
case "pane":
    guard rest.count == 1 else { fail("pane <title>") }
    let entries = controls(kAXRowRole)
    guard let entry = entries.first(where: { paneTitle($0) == rest[0] }) else {
        fail("the sidebar lists \(entries.map(paneTitle)) and none is \(rest[0])")
    }
    guard AXUIElementSetAttributeValue(entry, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success else {
        fail("the sidebar did not select \(rest[0])")
    }
case "theme":
    guard rest.count == 1 else { fail("theme <title>") }
    let tiles = controls(kAXRadioButtonRole)
    guard let tile = tiles.first(where: { title($0) == rest[0] }) else {
        fail("the window shows the tiles \(tiles.map(title)) and none is \(rest[0]); run `pane Theme`")
    }
    press(tile, rest[0])
    usleep(200_000)
    print("tile \(rest[0]) value=\(state(tile))")
case "theme-of":
    let appearances = ["Light", "Dark"], popUps = controls(kAXPopUpButtonRole)
    guard rest.count == 2, let index = appearances.firstIndex(of: rest[0]) else { fail("theme-of <Light|Dark> <title>") }
    guard popUps.count == appearances.count else {
        fail("the window shows \(popUps.count) pop-ups, not one for each appearance; run `pane Theme`")
    }
    let items = open(popUps[index])
    print("lists \(items.map(title))")
    choose(rest[1], of: items, in: popUps[index], "the \(rest[0]) theme")
case "pick":
    guard rest.count == 2 else { fail("pick <row> <title>") }
    let popUp = control(kAXPopUpButtonRole, "pop-ups")
    choose(rest[1], of: open(popUp), in: popUp, "row \(rest[0])")
case "size":
    guard rest.count == 2 else { fail("size <n> <text>") }
    let field = control(kAXTextFieldRole, "size fields")
    guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, rest[1] as CFString) == .success else {
        fail("the field did not take the text")
    }
    perform(kAXConfirmAction, on: field, "the size field")
    usleep(200_000)
    print("size \(rest[0]) value=\(value(field))")
case "step":
    guard rest.count >= 2, ["up", "down"].contains(rest[1]) else { fail("step <n> up|down [count]") }
    let stepper = control(kAXIncrementorRole, "steppers")
    for _ in 0..<(rest.count > 2 ? Int(number(2)) : 1) {
        perform(rest[1] == "up" ? kAXIncrementAction : kAXDecrementAction, on: stepper, "the stepper")
        usleep(150_000)
    }
case "focus":
    let field = control(kAXTextFieldRole, "size fields")
    guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
        fail("the field did not take the focus")
    }
case "type":
    guard rest.count == 1 else { fail("type <text>") }
    for character in rest[0] { post(255, character: character) }
case "press":
    guard rest.count == 1, let code = CGKeyCode(rest[0]) else { fail("press <key code>") }
    post(code)
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
