import AppKit

final class StatusMenuController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onReloadConfig: (() -> Void)?
    var onShowPermissions: (() -> Void)?

    init() {
        item.button?.title = "Sable"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Check Permissions", action: #selector(showPermissions), keyEquivalent: "p"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
    }

    @objc private func reloadConfig() {
        onReloadConfig?()
    }

    @objc private func showPermissions() {
        onShowPermissions?()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
