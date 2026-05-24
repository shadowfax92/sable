import AppKit
import SableCore
import SwiftUI

/// Hosts the SwiftUI dashboard inside an AppKit window so the menu-bar app can
/// still own window lifecycle while the UI is declarative. AppCoordinator talks
/// to this controller; this controller forwards to the SwiftUI model.
@MainActor
final class MainWindowController: NSWindowController {
    private let model = MainWindowModel()

    var onReloadConfig: (() -> Void)? {
        get { model.onReloadConfig }
        set { model.onReloadConfig = newValue }
    }
    var onShowPermissions: (() -> Void)? {
        get { model.onShowPermissions }
        set { model.onShowPermissions = newValue }
    }
    var onClearHistory: (() -> Void)? {
        get { model.onClearHistory }
        set { model.onClearHistory = newValue }
    }
    var onCopyOutput: ((RunRecord) -> Void)? {
        get { model.onCopyOutput }
        set { model.onCopyOutput = newValue }
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sable"
        window.contentMinSize = NSSize(width: 820, height: 520)
        window.center()

        super.init(window: window)

        window.contentView = NSHostingView(rootView: MainView().environmentObject(model))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens the operational dashboard where Sable shows config, permissions, current run, and history.
    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setStatus(_ status: DashboardStatus) {
        model.status = status
    }

    func setRecords(_ records: [RunRecord]) {
        model.setRecords(records)
    }
}
