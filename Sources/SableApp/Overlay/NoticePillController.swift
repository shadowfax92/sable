import AppKit
import SwiftUI

/// A panel that can never become key. The pill reports progress and outcomes
/// without moving keyboard focus away from the user's app.
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the non-key HUD pill at the top center of the screen with the mouse.
/// It works independently of the main panel: a quick-copy run from a direct
/// hotkey can show running, copied and failure notices without ever presenting
/// the key panel.
///
/// Each notice carries its own interaction ID, and its callbacks report that ID
/// (not the panel's, which may be nil). Every show bumps a token, so a pending
/// auto-dismiss can never hide a newer notice.
@MainActor
final class NoticePillController {
    var onAction: ((OverlayFailure.Action, UUID) -> Void)?
    var onCancel: ((UUID) -> Void)?

    private var panel: NonKeyPanel?
    private var hosting: FirstMouseHostingView<NoticePillView>?
    private var notice: OverlayNotice?
    private var interactionID: UUID?
    private var token = 0

    func show(_ notice: OverlayNotice, interactionID: UUID?) {
        token += 1
        let token = token
        self.notice = notice
        self.interactionID = interactionID
        let panel = ensurePanel()
        hosting?.rootView = view(for: notice)
        position(panel)
        panel.orderFrontRegardless()

        if let duration = notice.duration {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard let self, self.token == token else { return }
                self.hide()
            }
        }
    }

    /// Closes the pill if it still belongs to `interactionID`; nil closes
    /// whatever is showing.
    func close(interactionID: UUID?) {
        guard notice != nil else { return }
        guard interactionID == nil || interactionID == self.interactionID else { return }
        hide()
    }

    private func hide() {
        token += 1
        notice = nil
        panel?.orderOut(nil)
    }

    private func view(for notice: OverlayNotice) -> NoticePillView {
        NoticePillView(
            notice: notice,
            onPrimary: { [weak self] in self?.performPrimary() },
            onClose: { [weak self] in self?.closeTapped() }
        )
    }

    private func performPrimary() {
        guard case let .failure(failure) = notice else { return }
        let id = interactionID
        hide()
        if failure.primaryAction != .close, let id {
            onAction?(failure.primaryAction, id)
        }
    }

    private func closeTapped() {
        let wasRunning: Bool
        if case .running = notice { wasRunning = true } else { wasRunning = false }
        let id = interactionID
        hide()
        if wasRunning, let id { onCancel?(id) }
    }

    private func ensurePanel() -> NonKeyPanel {
        if let panel { return panel }
        let hosting = FirstMouseHostingView(rootView: view(for: .copied))
        let panel = NonKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    private func position(_ panel: NonKeyPanel) {
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = Self.pillOrigin(size: size, in: visible)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Top center, just under the menu bar. The pill's transparent margin
    /// (`NoticePillView.margin`) already gives breathing room.
    nonisolated static func pillOrigin(size: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height)
    }
}

/// Pill content. Rebuilt per notice, so sizing reflects the new content at once.
struct NoticePillView: View {
    static let margin: CGFloat = 16

    let notice: OverlayNotice
    let onPrimary: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            content
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 240, maxWidth: 420, minHeight: 36)
        .background(OverlaySurface())
        .clipShape(Capsule())
        .overlay(Capsule().stroke(OverlayTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .padding(Self.margin)
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch notice {
        case let .running(modeName):
            BreathingDot()
            label("\(modeName) · Rewriting")
            Spacer(minLength: 6)
            closeButton
        case .copied:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OverlayTheme.ok)
            label("Copied")
            Text("⌘V to paste")
                .font(.system(size: 12))
                .foregroundStyle(OverlayTheme.textTertiary)
            Spacer(minLength: 0)
        case let .message(title, detail):
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OverlayTheme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                label(title)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OverlayTheme.textTertiary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 6)
            Spacer(minLength: 0)
        case let .failure(failure):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OverlayTheme.warn)
            VStack(alignment: .leading, spacing: 1) {
                if failure.showsChatGPTIdentity {
                    Text("ChatGPT")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(OverlayTheme.textSecondary)
                }
                label(failure.title)
            }
            .padding(.vertical, 6)
            Spacer(minLength: 6)
            if failure.primaryAction != .close {
                Button(failure.primaryAction.title, action: onPrimary)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OverlayTheme.accentInk)
            }
            closeButton
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(OverlayTheme.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(OverlayTheme.textTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Cancel")
    }
}
