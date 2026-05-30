import AppKit
import SableCore
import SwiftUI

/// Hosts the SwiftUI app shell inside an AppKit window. `AppCoordinator` talks to
/// the exposed `model` directly — setting callbacks and pushing records,
/// settings, and permission state in.
@MainActor
final class MainWindowController: NSWindowController {
    let model = MainWindowModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sable"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.center()

        super.init(window: window)

        window.contentView = NSHostingView(rootView: MainView().environmentObject(model))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
