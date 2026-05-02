import AppKit

final class StatusMenuController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onOpen: (() -> Void)?
    var onReloadConfig: (() -> Void)?
    var onShowPermissions: (() -> Void)?
    var onClearHistory: (() -> Void)?

    init() {
        item.button?.title = "Sable"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Sable", action: #selector(openSable), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Check Permissions", action: #selector(showPermissions), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
    }

    func setState(_ state: String) {
        item.button?.title = state == "Idle" ? "Sable" : "Sable • \(state)"
    }

    @objc private func openSable() {
        onOpen?()
    }

    @objc private func reloadConfig() {
        onReloadConfig?()
    }

    @objc private func showPermissions() {
        onShowPermissions?()
    }

    @objc private func clearHistory() {
        onClearHistory?()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
