import SableCore
import SwiftUI

/// The dark, rounded Superwhisper-style popup. Uses only explicit colors from
/// `Theme.Overlay` because the app is pinned to a light appearance.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if !contextText.isEmpty {
                contextBox
            }
            statusRow
            Divider().overlay(Theme.Overlay.panelStroke)
            bottomBar
        }
        .padding(16)
        .frame(width: Theme.Metric.overlayWidth)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metric.overlayCorner, style: .continuous)
                .fill(Theme.Overlay.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metric.overlayCorner, style: .continuous)
                .stroke(Theme.Overlay.panelStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .padding(24) // breathing room inside the clear window for the shadow
        .onAppear { syncFocus() }
        .onChange(of: model.phase) { _ in syncFocus() }
        .onChange(of: model.focusNonce) { _ in syncFocus() }
    }

    // MARK: Context (selected text, or result on completion)

    private var contextText: String {
        if case let .done(result) = model.phase {
            return result
        }
        return model.selectedText
    }

    private var contextLabel: String {
        if case .done = model.phase { return "RESULT" }
        return "SELECTED TEXT"
    }

    private var contextBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(contextLabel)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.Overlay.textTertiary)
            ScrollView {
                Text(contextText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Overlay.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 92)
            .padding(10)
            .background(Theme.Overlay.field)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.Overlay.fieldStroke, lineWidth: 1)
            )
        }
    }

    // MARK: Status / input row

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 12) {
            icon
            switch model.phase {
            case .input:
                inputField
            case .thinking:
                ThinkingLabel()
            case .done:
                label("Copied to clipboard", color: Theme.Overlay.ok)
            case let .error(message):
                label(message, color: Theme.Overlay.error)
            }
        }
        .frame(minHeight: 30)
    }

    private var icon: some View {
        Group {
            switch model.phase {
            case .thinking:
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.Overlay.accent)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Overlay.ok)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Overlay.error)
            case .input:
                Image(systemName: model.modeSymbol)
                    .foregroundStyle(Theme.Overlay.accent)
            }
        }
        .font(.system(size: 17, weight: .medium))
        .frame(width: 22, height: 22)
    }

    private var inputField: some View {
        ZStack(alignment: .leading) {
            if model.input.isEmpty {
                Text(placeholder)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.Overlay.textTertiary)
            }
            TextField("", text: $model.input)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Theme.Overlay.textPrimary)
                .focused($inputFocused)
                .onSubmit { model.onSubmit?(model.input) }
        }
    }

    private var placeholder: String {
        model.requiresInput ? "Ask anything about the selection…" : "Press ⏎ to run \(model.modeName)"
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            modeChip
            Spacer(minLength: 8)
            controls
        }
    }

    private var modeChip: some View {
        Menu {
            ForEach(model.modes) { mode in
                Button {
                    model.onPickMode?(mode.id)
                } label: {
                    Label(mode.name, systemImage: mode.symbol)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.modeSymbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(model.modeName)
                    .font(.system(size: 12.5, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Overlay.textTertiary)
            }
            .foregroundStyle(Theme.Overlay.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.Overlay.chip)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .input:
            HStack(spacing: 8) {
                KeyHint(text: "Run", cap: "⏎")
                KeyHint(text: "Cancel", cap: "esc")
            }
        case .thinking:
            KeyHint(text: "Cancel", cap: "esc")
        case .done, .error:
            KeyHint(text: "Close", cap: "esc")
        }
    }

    private func syncFocus() {
        guard model.phase == .input else {
            inputFocused = false
            return
        }
        // Defer so the assertion lands after the panel has become key on first show.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            if model.phase == .input {
                inputFocused = true
            }
        }
    }
}

/// "Thinking" with an animated trailing ellipsis so the user can see the agent
/// is working.
private struct ThinkingLabel: View {
    @State private var dots = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("Thinking" + String(repeating: ".", count: dots))
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.Overlay.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onReceive(timer) { _ in dots = (dots + 1) % 4 }
    }
}

private struct KeyHint: View {
    let text: String
    let cap: String

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Overlay.textTertiary)
            Text(cap)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Overlay.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.Overlay.chip)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}
