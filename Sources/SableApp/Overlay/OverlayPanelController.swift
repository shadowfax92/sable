import AppKit
import SableCore
import SwiftUI

/// Borderless panel that can still receive text input.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating popup panel and its SwiftUI content.
@MainActor
final class OverlayPanelController {
    let model = OverlayModel()
    private var panel: KeyablePanel?
    private var keyMonitor: Any?

    func present(mode: SableMode, selectedText: String, modes: [SableMode]) {
        model.configure(mode: mode, selectedText: selectedText, modes: modes)
        showPanel()
    }

    func presentPicker(selectedText: String, modes: [SableMode], initialModeID: UUID?) {
        model.configurePicker(selectedText: selectedText, modes: modes, initialModeID: initialModeID)
        showPanel()
    }

    func showPicker() {
        model.showPicker()
        resizeAfterLayout()
    }

    private func showPanel() {
        let panel = ensurePanel()
        installMonitor()
        sizeAndPosition(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        removeMonitor()
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func ensurePanel() -> KeyablePanel {
        if let panel {
            return panel
        }
        let hosting = NSHostingView(rootView: OverlayView(model: model))
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.Metric.overlayWidth + 48, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .aqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }

    /// Sizes the panel from SwiftUI content and keeps it inside the visible screen.
    private func sizeAndPosition(_ panel: KeyablePanel) {
        guard let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 1 || size.height < 1 {
            size = NSSize(width: Theme.Metric.overlayWidth + 48, height: 220)
        }
        panel.setContentSize(size)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 8)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }

    private func resizeAfterLayout() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            self.sizeAndPosition(panel)
        }
    }

    /// Routes panel-level keys that SwiftUI controls do not handle consistently.
    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else {
                return event
            }
            switch event.keyCode {
            case 53: // escape
                self.model.onCancel?()
                return nil
            case 36, 76: // return / enter
                switch self.model.phase {
                case .picking:
                    self.model.pickHighlightedMode()
                    return nil
                case .done, .error:
                    self.model.onCancel?()
                    return nil
                default:
                    return event
                }
            case 125: // down
                guard self.model.phase == .picking else { return event }
                self.model.selectNextMode()
                return nil
            case 126: // up
                guard self.model.phase == .picking else { return event }
                self.model.selectPreviousMode()
                return nil
            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
