import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No app-wide appearance pin: the utility window follows the system
        // light/dark setting through Theme's adaptive colors.
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

    /// Target of "Settings… ⌘," and View ⌘1–⌘3, reached through the responder
    /// chain so the shortcuts work even while the window is closed. The
    /// coordinator owns the window, so this shows it through the coordinator and
    /// leaves the tab switch to `MainWindowController`, which observes the
    /// notification. `representedObject` is a `NavSection.rawValue`.
    @MainActor @objc func showSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, NavSection(rawValue: raw) != nil else { return }
        NotificationCenter.default.post(name: .sableShowSection, object: raw)
        coordinator?.showMainWindow()
    }
}
