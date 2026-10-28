import AppKit
import Combine
import SableCore
import SwiftUI

/// Hosts the SwiftUI utility window inside an AppKit window. `AppCoordinator`
/// talks to the exposed `model` directly, setting callbacks and pushing records,
/// settings and permission state in.
///
/// The Modes | History | Settings switcher is a native segmented control in a
/// compact unified toolbar, kept in two-way sync with `model.section`. Main-menu
/// navigation arrives as `.sableShowSection` notifications (see `AppDelegate`).
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    let model = MainWindowModel()

    private static let sectionItem = NSToolbarItem.Identifier("sable.section")
    private let sectionControl = NSSegmentedControl(
        labels: NavSection.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var cancellables = Set<AnyCancellable>()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sable"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.contentMinSize = NSSize(width: 680, height: 460)
        // Closing only hides the window: the coordinator keeps this controller
        // for the app's lifetime and reopens the same window.
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        sectionControl.target = self
        sectionControl.action = #selector(sectionControlChanged(_:))
        sectionControl.segmentStyle = .automatic

        let toolbar = NSToolbar(identifier: "sable.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.sectionItem]
        window.toolbar = toolbar

        window.contentView = NSHostingView(rootView: MainView().environmentObject(model))

        // Model → control. Covers the menu, the coordinator jumping to Settings
        // and the banner, as well as the control's own clicks.
        model.$section
            .sink { [weak self] section in
                self?.sectionControl.selectedSegment = NavSection.allCases.firstIndex(of: section) ?? 0
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .sableShowSection)
            .compactMap { ($0.object as? String).flatMap(NavSection.init(rawValue:)) }
            .sink { [weak self] section in self?.model.section = section }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func sectionControlChanged(_ sender: NSSegmentedControl) {
        guard NavSection.allCases.indices.contains(sender.selectedSegment) else { return }
        model.section = NavSection.allCases[sender.selectedSegment]
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.sectionItem, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.sectionItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = sectionControl
        item.label = "Section"
        return item
    }
}
