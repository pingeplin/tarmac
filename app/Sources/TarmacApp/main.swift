import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named: .darkAqua)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
