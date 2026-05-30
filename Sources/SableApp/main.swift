import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Dock app: a regular activation policy gives Sable a Dock icon and a main
// window, rather than the old menu-bar-only accessory.
app.setActivationPolicy(.regular)
app.run()
