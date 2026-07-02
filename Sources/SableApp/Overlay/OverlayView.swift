import SableCore
import SwiftUI

/// Renders the floating picker, instruction, and run-status popup.
struct OverlayView: View {
    private enum FocusField: Hashable {
        case picker
        case input
    }

    @ObservedObject var model: OverlayModel
    @FocusState private var focusedField: FocusField?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if !contextText.isEmpty {
                contextBox
            }
            mainContent
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

    @ViewBuilder
    private var mainContent: some View {
        switch model.phase {
        case .picking:
            pickerContent
        default:
            statusRow
        }
    }

    // MARK: Picker

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            pickerSearchField
            modeList
        }
    }

    private var pickerSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Overlay.textTertiary)
                .frame(width: 18, height: 18)

            ZStack(alignment: .leading) {
                if model.pickerQuery.isEmpty {
                    Text("Choose a mode…")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.Overlay.textTertiary)
                }
                TextField(
                    "",
                    text: Binding(
                        get: { model.pickerQuery },
                        set: { model.setPickerQuery($0) }
                    )
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.Overlay.textPrimary)
                    .focused($focusedField, equals: .picker)
                    .onSubmit { model.pickHighlightedMode() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.Overlay.field)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.Overlay.fieldStroke, lineWidth: 1)
        )
    }

    private var modeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.visibleModes) { mode in
                        ModePickerRow(
                            mode: mode,
                            isHighlighted: model.highlightedModeID == mode.id,
                            action: { model.onPickMode?(mode.id) },
                            onHover: { model.highlightMode(mode.id) }
                        )
                        .id(mode.id)
                    }

                    if model.visibleModes.isEmpty {
                        Text("No matching modes")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Overlay.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 54)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: 286)
            .onAppear { scrollHighlightedMode(with: proxy) }
            .onChange(of: model.highlightedModeID) { _ in scrollHighlightedMode(with: proxy) }
        }
    }

    private func scrollHighlightedMode(with proxy: ScrollViewProxy) {
        guard let id = model.highlightedModeID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    // MARK: Status / input row

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 12) {
            icon
            switch model.phase {
            case .picking:
                EmptyView()
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
            case .picking:
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Theme.Overlay.accent)
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
                .focused($focusedField, equals: .input)
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

    @ViewBuilder
    private var bottomBar: some View {
        switch model.phase {
        case .picking:
            HStack(spacing: 8) {
                KeyHint(text: "Select", cap: "⏎")
                KeyHint(text: "Move", cap: "↑↓")
                Spacer(minLength: 8)
                KeyHint(text: "Cancel", cap: "esc")
            }
        default:
            HStack(spacing: 10) {
                modeChip
                Spacer(minLength: 8)
                controls
            }
        }
    }

    private var modeChip: some View {
        Button {
            if model.phase == .input {
                model.showPicker()
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
        .buttonStyle(.plain)
        .disabled(model.phase != .input)
        .fixedSize()
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .picking:
            EmptyView()
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
        let target: FocusField?
        switch model.phase {
        case .picking:
            target = .picker
        case .input:
            target = .input
        default:
            target = nil
        }

        guard let target else {
            focusedField = nil
            return
        }
        // Defer so the assertion lands after the panel has become key on first show.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            switch (target, model.phase) {
            case (.picker, .picking), (.input, .input):
                focusedField = target
            default:
                break
            }
        }
    }
}

private struct ModePickerRow: View {
    let mode: SableMode
    let isHighlighted: Bool
    let action: () -> Void
    let onHover: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.Overlay.accent)
                    .frame(width: 30, height: 30)
                    .background(Theme.Overlay.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.name.isEmpty ? "Untitled mode" : mode.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.Overlay.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Overlay.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(RuntimeDefinitions.definition(for: mode.runtimeID).displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Overlay.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.Overlay.chip)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHighlighted ? Theme.Overlay.accent.opacity(0.10) : Theme.Overlay.field)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isHighlighted ? Theme.Overlay.accent.opacity(0.35) : Theme.Overlay.fieldStroke,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { onHover() }
        }
    }

    private var subtitle: String {
        let kind = mode.requiresInput ? "Asks for instruction" : "Runs instantly"
        let modelLabel = RuntimeDefinitions.modelLabel(for: mode.model, runtime: mode.runtimeID)
        return "\(kind) · \(modelLabel)"
    }
}

/// Animated run-progress label.
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
