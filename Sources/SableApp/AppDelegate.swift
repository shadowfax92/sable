import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sable is a light-only app; pin the appearance so adaptive colors and
        // window chrome don't render dark text on light surfaces under dark mode.
        NSApp.appearance = NSAppearance(named: .aqua)
        coordinator = AppCoordinator()
        coordinator?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
