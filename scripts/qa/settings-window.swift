// Operates the Settings window of the live dev app with no pointer (specs
// 2610.0005, 2610.0006, 2610.0007, 2610.0008, 2610.0009), through the Accessibility API, and posts
// a click or a wheel at a screen point for the one scenario that needs real
// pointer events.
//
//   swift scripts/qa/settings-window.swift <pid> <verb> ...
//
//   open                     posts ⌘, to the app
//   rows                     prints the window's frame, the selected pane, each row's selected title, each size, each theme tile with its value (1 = selected), and the window's labels, with frames; on the Theme pane also each row of the list of themes with its marks and, last on the line, its id; the frame of the list as it shows; the showcase's title and caption, its picture, its two boxes, its note and the note's tooltip; and the line about the theme files, its tooltip and the button. A tooltip's line breaks print as " | "
//   pane <title>             selects a sidebar entry: Fonts, Theme
//   theme <title>            presses a tile of the Theme pane: Auto, Light, Dark
//   show <title or id>       selects a row of the Theme pane's list, which puts that theme in the showcase and changes nothing else; an id names one row, and a title the first row that has it
//   open-themes              presses Open Themes Folder
//   apply <Light|Dark> on|off  sets or clears that box of the showcase; its last line is the box as it is then
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
// shows: they need the Fonts pane, and `theme`, `show`, `apply` and
// `open-themes` need the Theme pane.
//
// `apply` presses nothing and exits 1 when the box is disabled, and when it
// is already in the state that was asked for. `show` and `pane` exit 1 for a
// title, or for `show` an id, their own table does not hold: the sidebar and the list of themes are
// two tables, and the app names each for the Accessibility API.
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

/// Every element of the Settings window, read once for a run: with some
/// hundreds of theme files a walk of the window takes seconds. An element
/// stays good after a press, and its value is read again each time.
var windowViews: [AXUIElement]?

func views() -> [AXUIElement] {
    if let windowViews { return windowViews }
    let read = descendants(of: settingsWindow())
    windowViews = read
    return read
}

func controls(_ wanted: String) -> [AXUIElement] {
    views().filter { role($0) == wanted }
}

func identifier(_ element: AXUIElement) -> String { attribute(element, kAXIdentifierAttribute) ?? "" }

/// The names the app gives the two tables and the parts of the showcase.
let sidebar = "settings-sidebar", themeList = "theme-list"
let showcaseTitle = "theme-showcase-title", showcaseCaption = "theme-showcase-caption"
let showcasePicture = "theme-showcase-picture", contrastNote = "theme-contrast-note"
let filesNote = "theme-files-note", openThemes = "Open Themes Folder"

func named(_ name: String) -> AXUIElement? {
    views().first { identifier($0) == name }
}

/// The rows of one table, or none while its pane does not show.
func rows(of table: String) -> [AXUIElement] {
    named(table).map { descendants(of: $0).filter { role($0) == kAXRowRole } } ?? []
}

func selected(_ row: AXUIElement) -> Bool { (attribute(row, kAXSelectedAttribute) as Bool?) == true }

/// The texts of a row's cell: its title and then, in the list of themes, its
/// marks.
func texts(_ row: AXUIElement) -> [String] {
    descendants(of: row).filter { role($0) == kAXStaticTextRole }.map(value)
}

func rowName(_ row: AXUIElement) -> String { texts(row).first ?? "" }

/// The id the app gives a row of the list of themes, on the row's title.
func rowID(_ row: AXUIElement) -> String {
    descendants(of: row).map(identifier).first { !$0.isEmpty } ?? ""
}

/// A tooltip on one line, or nothing when the element has none.
func help(_ element: AXUIElement) -> String {
    ((attribute(element, kAXHelpAttribute) as String?) ?? "").replacingOccurrences(of: "\n", with: " | ")
}

/// Selects the row with that name, as a click on it does: in the list of
/// themes the row with that id, or else the first row with that title.
/// `found` starts the line that tells of a name no row has.
func select(_ name: String, in table: String, _ found: String, hint: String = "") {
    let entries = rows(of: table)
    guard let row = entries.first(where: { rowID($0) == name }) ?? entries.first(where: { rowName($0) == name })
    else {
        fail("\(found) \(entries.map(rowName)) and none is \(name)\(hint)")
    }
    guard AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success else {
        fail("the row \(name) was not selected")
    }
}

/// 1 for the selected radio button and for a box that is set, 0 for another.
func state(_ element: AXUIElement) -> Int {
    (attribute(element, kAXValueAttribute) as NSNumber?)?.intValue ?? -1
}

func enabled(_ element: AXUIElement) -> Bool { (attribute(element, kAXEnabledAttribute) as Bool?) == true }

/// A box of the showcase, as `rows` and `apply` print it.
func box(_ element: AXUIElement) -> String {
    "box \(title(element)) value=\(state(element)) enabled=\(enabled(element) ? 1 : 0)"
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
    let window = settingsWindow(), views = views()
    print("window frame=\(frame(window))")
    print("pane=\(rows(of: sidebar).filter(selected).map(rowName).joined(separator: ","))")
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
    for row in rows(of: themeList) {
        let marks = texts(row).dropFirst().joined(separator: ",")
        print(
            "theme \(rowName(row)) marks=\(marks) selected=\(selected(row) ? 1 : 0) frame=\(frame(row)) id=\(rowID(row))"
        )
    }
    if let list = named(themeList), let scroll: AXUIElement = attribute(list, kAXParentAttribute) {
        print("list frame=\(frame(scroll))")
    }
    if let shown = named(showcaseTitle) {
        print("showcase title=\(value(shown)) caption=\(named(showcaseCaption).map(value) ?? "")")
    }
    if let picture = named(showcasePicture) { print("picture frame=\(frame(picture))") }
    for element in views.filter({ role($0) == kAXCheckBoxRole }) { print("\(box(element)) frame=\(frame(element))") }
    if let note = named(contrastNote) {
        print("note \(value(note))")
        print("note-help \(help(note))")
    }
    if let files = named(filesNote) {
        print("files \(value(files))")
        print("files-help \(help(files))")
    }
    for button in views.filter({ role($0) == kAXButtonRole && title($0) == openThemes }) {
        print("button \(openThemes) frame=\(frame(button))")
    }
    let texts = views.filter { role($0) == kAXStaticTextRole }
    for text in texts { print("label \(value(text)) frame=\(frame(text))") }
    print("labels=\(texts.map(value))")
    print("resizable=\((attribute(window, "AXGrowArea") as AXUIElement?) != nil)")
case "pane":
    guard rest.count == 1 else { fail("pane <title>") }
    select(rest[0], in: sidebar, "the sidebar lists")
case "theme":
    guard rest.count == 1 else { fail("theme <title>") }
    let tiles = controls(kAXRadioButtonRole)
    guard let tile = tiles.first(where: { title($0) == rest[0] }) else {
        fail("the window shows the tiles \(tiles.map(title)) and none is \(rest[0]); run `pane Theme`")
    }
    press(tile, rest[0])
    usleep(200_000)
    print("tile \(rest[0]) value=\(state(tile))")
case "show":
    guard rest.count == 1 else { fail("show <title or id>") }
    select(rest[0], in: themeList, "the list of themes holds", hint: "; run `pane Theme`")
    usleep(200_000)
    print("shown \(named(showcaseTitle).map(value) ?? "")")
case "open-themes":
    guard let button = controls(kAXButtonRole).first(where: { title($0) == openThemes }) else {
        fail("the window shows no button titled \(openThemes); run `pane Theme`")
    }
    press(button, openThemes)
case "apply":
    guard rest.count == 2, ["Light", "Dark"].contains(rest[0]), ["on", "off"].contains(rest[1]) else {
        fail("apply <Light|Dark> on|off")
    }
    let name = "Apply to \(rest[0])"
    guard let element = controls(kAXCheckBoxRole).first(where: { title($0) == name }) else {
        fail("the window shows no box titled \(name); run `pane Theme`")
    }
    let wanted = rest[1] == "on" ? 1 : 0
    let refusal = !enabled(element) ? "is disabled" : state(element) == wanted ? "is already \(rest[1])" : nil
    if refusal == nil {
        press(element, name)
        usleep(200_000)
    }
    print(box(element))
    if let refusal { fail("the box \(name) \(refusal)") }
case "pick":
    guard rest.count == 2 else { fail("pick <row> <title>") }
    let popUp = control(kAXPopUpButtonRole, "pop-ups")
    press(popUp, "the pop-up")
    usleep(400_000)
    let items = descendants(of: popUp).filter { role($0) == kAXMenuItemRole }
    guard let item = items.first(where: { title($0) == rest[1] }) else {
        AXUIElementPerformAction(popUp, kAXCancelAction as CFString)
        fail("row \(rest[0]) lists \(items.count) entries and none is \(rest[1])")
    }
    press(item, rest[1])
    print("picked \(rest[1]) of \(items.count)")
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
