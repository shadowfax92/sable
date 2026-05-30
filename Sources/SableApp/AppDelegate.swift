import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sable is a light-only app; pin the appearance so adaptive colors and
        // window chrome don't render dark text on light surfaces under dark mode.
        // The floating popup opts back into dark via its own window appearance.
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.mainMenu = MainMenu.build()
        coordinator = AppCoordinator()
        coordinator?.start()
    }

    // Global hotkeys must keep working after the window is closed, so don't quit
    // on last-window-close; the Dock icon reopens the window instead.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
