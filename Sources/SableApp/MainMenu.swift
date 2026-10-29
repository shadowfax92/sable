import AppKit

enum MainMenu {
    /// Builds the app's main menu. SPM executables get no menu by default, and
    /// the Edit menu in particular is required — without it the standard
    /// Cut/Copy/Paste/Select All actions never reach text fields (so ⌘V wouldn't
    /// work in the popup or settings). "Settings… ⌘," and View ⌘1–⌘3 open the
    /// utility window on a tab through `AppDelegate.showSection(_:)`.
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(sectionItem("Settings…", section: .settings, key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        // AppKit's standard `undo:`/`redo:` aren't in its Swift headers, so the
        // selectors are named through ReviewTextView's matching @objc methods.
        // The class only spells the selector: the nil target still sends it up
        // the responder chain, where ReviewTextView handles it in review and
        // NSWindow's undo manager handles it for every other text control.
        editMenu.addItem(withTitle: "Undo", action: #selector(ReviewTextView.undo(_:)), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: #selector(ReviewTextView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        for (index, section) in NavSection.allCases.enumerated() {
            viewMenu.addItem(sectionItem(section.title, section: section, key: "\(index + 1)"))
        }

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    /// Opens the utility window on `section`. The nil target sends
    /// `showSection:` up the responder chain to `AppDelegate`, which is always
    /// reachable, so the shortcut also reopens a closed window.
    private static func sectionItem(_ title: String, section: NavSection, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(AppDelegate.showSection(_:)), keyEquivalent: key)
        item.representedObject = section.rawValue
        return item
    }
}
