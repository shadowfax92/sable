import AppKit
import Combine
import SableCore
import SwiftUI

/// Borderless panel that can still receive text input.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating panel, its SwiftUI content and the non-key notice pill.
/// This is the presentation API the interaction owner drives; the exact
/// contract is in fast-rewrite/overlay-contracts.md.
///
/// Focus model: the panel is a key-capable, `.nonactivatingPanel`, so it takes
/// keyboard input without activating Sable. The source app stays frontmost, and
/// key focus returns to it when the panel orders out. Key focus is taken only by
/// `present` / `presentPicker`, in direct response to a hotkey; later phase
/// changes (a run completing) never re-key the panel.
///
/// Every interaction-scoped show/close is keyed by `interactionID` and ignored
/// when stale, so a late completion or timer can't touch a newer interaction.
@MainActor
final class OverlayPanelController {
    let model = OverlayModel()
    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    private var layoutSubscription: AnyCancellable?
    private let notices = NoticePillController()

    init() {
        // Panel resizes are explicit model requests (phase switches, the review
        // editor growing), never inferred from individual text edits.
        layoutSubscription = model.$layoutRequest
            .dropFirst()
            .sink { [weak self] _ in self?.resizeAfterLayout() }
        notices.onAction = { [weak self] action, id in self?.model.onFailureAction?(action, id) }
        notices.onCancel = { [weak self] id in self?.model.onNoticeCancel?(id) }
    }

    var currentInteractionID: UUID? { model.interactionID }
    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Presenting (hotkey responses; these take key focus)

    func present(mode: SableMode, selectedText: String, modes: [SableMode]) {
        model.configure(mode: mode, selectedText: selectedText, modes: modes)
        showPanel()
    }

    func present(mode: SableMode, selectedText: String, modes: [SableMode], interactionID: UUID) {
        model.configure(mode: mode, selectedText: selectedText, modes: modes, interactionID: interactionID)
        showPanel()
    }

    func presentPicker(selectedText: String, modes: [SableMode], initialModeID: UUID?) {
        model.configurePicker(selectedText: selectedText, modes: modes, initialModeID: initialModeID)
        showPanel()
    }

    func presentPicker(selectedText: String, modes: [SableMode], initialModeID: UUID?, interactionID: UUID) {
        model.configurePicker(
            selectedText: selectedText, modes: modes, initialModeID: initialModeID, interactionID: interactionID
        )
        showPanel()
    }

    func showPicker() {
        model.showPicker()
    }

    // MARK: Interaction-scoped updates (never take focus)

    @discardableResult
    func showRunning(interactionID: UUID) -> Bool {
        guard isCurrent(interactionID) else { return false }
        model.showRunning()
        return true
    }

    /// Opens the review editor. If the panel isn't key (the user clicked away
    /// while the run finished), it stays non-key until clicked.
    @discardableResult
    func showReview(result: String, target: ReviewTarget, interactionID: UUID) -> Bool {
        guard isCurrent(interactionID) else { return false }
        model.presentReview(result: result, target: target)
        return true
    }

    @discardableResult
    func showCopied(text: String, interactionID: UUID, autoCloseAfter: TimeInterval? = 0.9) -> Bool {
        guard isCurrent(interactionID) else { return false }
        model.showCopied(text)
        if let delay = autoCloseAfter {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.model.interactionID == interactionID, case .done = self.model.phase else { return }
                self.close()
            }
        }
        return true
    }

    @discardableResult
    func showFailure(_ failure: OverlayFailure, interactionID: UUID) -> Bool {
        guard isCurrent(interactionID) else { return false }
        model.showFailure(failure)
        return true
    }

    @discardableResult
    func close(interactionID: UUID) -> Bool {
        guard isCurrent(interactionID) else { return false }
        close()
        return true
    }

    /// Closing always ends the interaction, so a review session that outlives
    /// its panel can't deliver a stale copy or paste.
    func close() {
        removeMonitor()
        panel?.orderOut(nil)
        model.invalidateSession()
    }

    // MARK: Notices (non-key pill, independent of the panel)

    func showNotice(_ notice: OverlayNotice, interactionID: UUID?) {
        notices.show(notice, interactionID: interactionID)
    }

    func closeNotice(interactionID: UUID?) {
        notices.close(interactionID: interactionID)
    }

    private func isCurrent(_ interactionID: UUID) -> Bool {
        model.interactionID == interactionID
    }

    // MARK: Panel

    private func showPanel() {
        let panel = ensurePanel()
        installMonitor()
        sizeAndPosition(panel, keepTop: panel.isVisible)
        // No NSApp.activate: a nonactivating panel receives keys without
        // activating Sable, which keeps the source app frontmost for paste-back.
        panel.makeKeyAndOrderFront(nil)
    }

    private func ensurePanel() -> KeyablePanel {
        if let panel {
            return panel
        }
        let hosting = NSHostingView(rootView: OverlayView(model: model))
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: OverlayTheme.Metric.width + 48, height: 220),
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
        // nil inherits the app/system appearance; overlay tokens are adaptive.
        panel.appearance = nil
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }

    /// Fits the panel to its content. A fresh presentation is centered with an
    /// upward bias; later resizes keep the top edge where it was, so the search
    /// field or editor doesn't jump while content grows or shrinks.
    private func sizeAndPosition(_ panel: KeyablePanel, keepTop: Bool) {
        guard let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 1 || size.height < 1 {
            size = NSSize(width: OverlayTheme.Metric.width + 48, height: 220)
        }
        let mouse = NSEvent.mouseLocation
        let screen = keepTop
            ? (panel.screen ?? NSScreen.main)
            : (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)
        guard let visible = screen?.visibleFrame else {
            panel.setFrame(NSRect(origin: NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 8), size: size), display: true)
            return
        }
        if !keepTop {
            model.reviewMaxEditorHeight = min(visible.height * 0.5, OverlayTheme.Metric.editorMaxHeight)
        }
        let origin = keepTop
            ? Self.anchoredOrigin(currentFrame: panel.frame, newSize: size, in: visible)
            : Self.spotlightOrigin(panelSize: size, in: visible)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Returns a Spotlight-style origin centered in the visible screen with a slight upward bias.
    nonisolated static func spotlightOrigin(
        panelSize size: NSSize,
        in visibleFrame: NSRect,
        margin: CGFloat = 8
    ) -> NSPoint {
        let verticalBias = min(visibleFrame.height * 0.12, 140)
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2 + verticalBias
        )
        let maxX = max(visibleFrame.minX + margin, visibleFrame.maxX - size.width - margin)
        let maxY = max(visibleFrame.minY + margin, visibleFrame.maxY - size.height - margin)
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX + margin), maxX),
            y: min(max(origin.y, visibleFrame.minY + margin), maxY)
        )
    }

    /// Origin for a resize that keeps the current top edge and horizontal center.
    /// It grows upward only when the bottom would leave the visible frame, and
    /// never pushes the top off-screen.
    nonisolated static func anchoredOrigin(
        currentFrame: NSRect,
        newSize size: NSSize,
        in visibleFrame: NSRect,
        margin: CGFloat = 8
    ) -> NSPoint {
        let maxX = max(visibleFrame.minX + margin, visibleFrame.maxX - size.width - margin)
        let x = min(max(currentFrame.midX - size.width / 2, visibleFrame.minX + margin), maxX)
        var y = min(currentFrame.maxY, visibleFrame.maxY - margin) - size.height
        y = max(y, visibleFrame.minY + margin)
        y = min(y, visibleFrame.maxY - margin - size.height)
        return NSPoint(x: x, y: y)
    }

    private func resizeAfterLayout() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            self.sizeAndPosition(panel, keepTop: true)
        }
    }

    // MARK: Keys

    /// Routes panel-level keys through `OverlayKeyRouter`. Keys pass through
    /// untouched while a text field's input method is composing, so Return
    /// commits the composition instead of picking a mode.
    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else {
                return event
            }
            if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = OverlayKeyRouter.Key(
                keyCode: event.keyCode,
                character: event.charactersIgnoringModifiers?.lowercased(),
                control: flags.contains(.control),
                command: flags.contains(.command)
            )
            switch OverlayKeyRouter.action(for: key, in: self.model.phase) {
            case .passThrough:
                return event
            case .swallow:
                return nil
            case .moveNext:
                self.model.selectNextMode()
            case .movePrevious:
                self.model.selectPreviousMode()
            case .pick:
                self.model.pickHighlightedMode()
            case .back:
                self.model.backFromInstruction()
            case .cancel:
                self.model.onCancel?()
            case .primaryAction:
                self.model.performFailureAction()
            case .closeLocally:
                self.close()
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
