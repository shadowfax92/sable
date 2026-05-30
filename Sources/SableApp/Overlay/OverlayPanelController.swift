import AppKit
import SableCore
import SwiftUI

/// A borderless `NSPanel` must explicitly opt in to key status, otherwise the
/// popup's text field can't receive keystrokes.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating popup window and its SwiftUI content. The coordinator drives
/// state by mutating `model` (phase, etc.) and wiring `model.onSubmit/onCancel`.
@MainActor
final class OverlayPanelController {
    let model = OverlayModel()
    private var panel: KeyablePanel?
    private var keyMonitor: Any?

    /// Shows the popup for a mode near the mouse, sized to its content.
    func present(mode: SableMode, selectedText: String, modes: [SableMode]) {
        model.configure(mode: mode, selectedText: selectedText, modes: modes)
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
        panel.hasShadow = false // SwiftUI draws the shadow
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }

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

    /// Routes Escape (and Return on a finished run) to the model so SwiftUI's text
    /// field doesn't swallow the keys.
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
                case .done, .error:
                    self.model.onCancel?()
                    return nil
                default:
                    return event
                }
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
