import KeyboardShortcuts
import SableCore
import SwiftUI

// MARK: - Picker

/// Flat, searchable mode list. Rows are single lines. The list height is fixed
/// for the session (`min(modes, 7)` rows), so filtering never resizes the panel.
struct PickerContent: View {
    @ObservedObject var model: OverlayModel
    var focus: FocusState<OverlayFocusField?>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var listHeight: CGFloat {
        let rows = min(max(model.modes.count, 1), OverlayTheme.Metric.maxVisibleRows)
        return CGFloat(rows) * OverlayTheme.Metric.rowHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SelectionPreview(text: model.selectedText)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OverlayTheme.textTertiary)
                TextField("Choose a mode…", text: Binding(
                    get: { model.pickerQuery },
                    set: { model.setPickerQuery($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused(focus, equals: .picker)
                .onSubmit { model.pickHighlightedMode() }
            }
            Hairline()
            modeList
            Hairline()
            HStack(spacing: 12) {
                KeyHint(text: "run", cap: "⏎")
                KeyHint(text: "move", cap: "⌃J ⌃K")
                Spacer(minLength: 8)
                KeyHint(text: "close", cap: "esc")
            }
        }
    }

    private var modeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleModes) { mode in
                        PickerRow(
                            mode: mode,
                            isHighlighted: model.highlightedModeID == mode.id,
                            isPickable: model.isModePickable(mode)
                        )
                        .id(mode.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.pickMode(mode.id) }
                        .onHover { hovering in
                            if hovering { model.highlightMode(mode.id) }
                        }
                    }
                    if model.visibleModes.isEmpty {
                        Text("No modes match “\(model.pickerQuery)”")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(OverlayTheme.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: listHeight)
                    }
                }
            }
            .frame(height: listHeight)
            .onChange(of: model.highlightedModeID) { id in
                guard let id else { return }
                if reduceMotion {
                    proxy.scrollTo(id)
                } else {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
        }
    }
}

private struct PickerRow: View {
    let mode: SableMode
    let isHighlighted: Bool
    let isPickable: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: mode.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isPickable ? OverlayTheme.textSecondary : OverlayTheme.textTertiary)
                .frame(width: 20)
            // A trailing ellipsis is the macOS convention for "asks for more input".
            Text((mode.name.isEmpty ? "Untitled mode" : mode.name) + (mode.requiresInput ? "…" : ""))
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(isPickable ? OverlayTheme.textPrimary : OverlayTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !isPickable {
                Text("needs selection")
                    .font(.system(size: 11))
                    .foregroundStyle(OverlayTheme.textTertiary)
            } else if let shortcut = KeyboardShortcuts.getShortcut(for: .mode(mode.id)) {
                Text(shortcut.description)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(OverlayTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: OverlayTheme.Metric.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHighlighted ? OverlayTheme.rowWash : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isHighlighted {
                Capsule()
                    .fill(OverlayTheme.accentFill)
                    .frame(width: 2.5, height: 16)
                    .padding(.leading, 2)
            }
        }
    }
}

// MARK: - Instruction

struct InstructionContent: View {
    @ObservedObject var model: OverlayModel
    var focus: FocusState<OverlayFocusField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SelectionPreview(text: model.selectedText)
            HStack(spacing: 10) {
                Button { model.onShowPicker?() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.modeSymbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(model.modeName)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(OverlayTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(OverlayTheme.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Choose another mode")

                TextField(placeholder, text: $model.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused(focus, equals: .input)
                    .onSubmit { model.onSubmit?(model.input) }
            }
            Hairline()
            HStack(spacing: 12) {
                KeyHint(text: model.requiresInput ? "rewrite" : "run", cap: "⏎")
                Spacer(minLength: 8)
                KeyHint(text: model.instructionReturnsToPicker ? "back" : "close", cap: "esc")
            }
        }
    }

    private var placeholder: String {
        model.requiresInput ? "Ask anything about the selection…" : "Press ⏎ to run \(model.modeName)"
    }
}

// MARK: - Running

/// Calm progress: static text, a breathing dot, and elapsed seconds only once a
/// run takes longer than 3 s. The output isn't streamed, so nothing else changes.
struct RunningContent: View {
    @ObservedObject var model: OverlayModel
    @State private var startedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ModeHeader(symbol: model.modeSymbol, name: model.modeName)
            SelectionPreview(text: model.selectedText, lineLimit: 2)
            Hairline()
            HStack(spacing: 8) {
                BreathingDot()
                Text("Rewriting")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OverlayTheme.textSecondary)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(startedAt))
                    Text(seconds >= 3 ? "\(seconds)s" : "")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(OverlayTheme.textTertiary)
                }
                KeyHint(text: "cancel", cap: "esc")
            }
        }
    }
}

// MARK: - Copied

struct CopiedContent: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OverlayTheme.ok)
                Text("Copied to clipboard")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(OverlayTheme.textPrimary)
                Spacer(minLength: 0)
            }
            if !text.isEmpty {
                SelectionPreview(text: text, lineLimit: 2)
            }
            Hairline()
            HStack(spacing: 12) {
                KeyHint(text: "paste", cap: "⌘V")
                Spacer(minLength: 8)
                KeyHint(text: "close", cap: "esc")
            }
        }
    }
}

// MARK: - Failure

/// One clear failure with a single primary action on ⏎. Plan-usage failures
/// keep a "ChatGPT" header so the ChatGPT identity stays visible.
struct FailureContent: View {
    let failure: OverlayFailure
    let onPrimary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if failure.showsChatGPTIdentity {
                Text("ChatGPT")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.3)
                    .foregroundStyle(OverlayTheme.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OverlayTheme.warn)
                Text(failure.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OverlayTheme.textPrimary)
            }
            Text(failure.message)
                .font(.system(size: 12.5))
                .foregroundStyle(OverlayTheme.textSecondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if let requestID = failure.requestID {
                Text("Request ID \(requestID)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(OverlayTheme.textTertiary)
                    .textSelection(.enabled)
            }
            Hairline()
                .padding(.top, 2)
            HStack(spacing: 12) {
                if failure.primaryAction != .close {
                    Button(action: onPrimary) {
                        KeyHint(text: failure.primaryAction.title, cap: "⏎")
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 8)
                KeyHint(text: "close", cap: "esc")
            }
        }
    }
}
