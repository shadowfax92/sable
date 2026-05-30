import AppKit
import KeyboardShortcuts
import SableCore
import SwiftUI

// MARK: - Layout primitives

/// Title + subtitle header shown at the top of every pane.
struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// White rounded card used to group settings and content.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cardCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metric.cardCorner, style: .continuous)
                    .stroke(Theme.Palette.cardStroke, lineWidth: 1)
            )
    }
}

/// A labelled settings row: title (+ optional help) on the left, control on the right.
struct FieldRow<Control: View>: View {
    let title: String
    var help: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let help {
                    Text(help)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .frame(maxWidth: .infinity)
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Runtime + model pickers

/// Claude / Codex harness picker. On change it resets the model when the current
/// selection isn't valid for the new harness.
struct RuntimePicker: View {
    @Binding var runtime: RuntimeID
    @Binding var model: String

    var body: some View {
        Picker("", selection: $runtime) {
            Text("Claude").tag(RuntimeID.claude)
            Text("Codex").tag(RuntimeID.codex)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 160)
        .onChange(of: runtime) { newValue in
            if !RuntimeDefinitions.models(for: newValue).contains(where: { $0.id == model }) {
                model = "default"
            }
        }
    }
}

struct ModelPicker: View {
    let runtime: RuntimeID
    @Binding var model: String

    var body: some View {
        Picker("", selection: $model) {
            ForEach(RuntimeDefinitions.models(for: runtime)) { option in
                Text(option.label).tag(option.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 180)
    }
}

/// Inline shortcut recorder bound to a `KeyboardShortcuts.Name`.
struct HotkeyRecorder: View {
    let name: KeyboardShortcuts.Name

    var body: some View {
        KeyboardShortcuts.Recorder(for: name)
    }
}

// MARK: - Permissions

struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Theme.Palette.chip)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            StatusChip(
                text: granted ? "Granted" : "Needed",
                symbol: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                color: granted ? Theme.Palette.ok : Theme.Palette.warn
            )

            Button(granted ? "Settings" : "Grant", action: action)
                .controlSize(.small)
        }
    }
}

// MARK: - Status visuals

struct StatusChip: View {
    let text: String
    let symbol: String
    let color: Color
    var busy: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
            } else {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            }
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

extension RunStatus {
    var tint: Color {
        switch self {
        case .capturing, .running: return Theme.Palette.running
        case .copied: return Theme.Palette.ok
        case .failed: return Theme.Palette.error
        case .cancelled: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .capturing: return "camera.viewfinder"
        case .running: return "sparkles"
        case .copied: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    var isBusy: Bool { self == .capturing || self == .running }
}

/// Maps the free-text run status to a chip color/symbol for the Home/sidebar badge.
struct RunVisual {
    let color: Color
    let symbol: String
    let busy: Bool

    static func from(_ text: String) -> RunVisual {
        let lowered = text.lowercased()
        if lowered.contains("captur") || lowered.contains("running") || lowered.contains("thinking") {
            return RunVisual(color: Theme.Palette.running, symbol: "circle.dotted", busy: true)
        }
        if lowered.contains("copied") || lowered.contains("done") {
            return RunVisual(color: Theme.Palette.ok, symbol: "checkmark.circle.fill", busy: false)
        }
        if lowered.contains("fail") {
            return RunVisual(color: Theme.Palette.error, symbol: "exclamationmark.triangle.fill", busy: false)
        }
        if lowered.contains("cancel") {
            return RunVisual(color: .secondary, symbol: "slash.circle", busy: false)
        }
        if lowered.contains("permission") {
            return RunVisual(color: Theme.Palette.warn, symbol: "lock.shield", busy: false)
        }
        return RunVisual(color: .secondary, symbol: "circle", busy: false)
    }
}

/// Monospaced read-only text panel used in the history detail.
struct CodeBlock: View {
    let text: String
    let minHeight: CGFloat
    let placeholder: String

    var body: some View {
        let isEmpty = text.isEmpty
        return ScrollView {
            Text(isEmpty ? placeholder : text)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(isEmpty ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minHeight: minHeight)
        .background(Theme.Palette.code)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.codeCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metric.codeCorner, style: .continuous)
                .stroke(Theme.Palette.codeStroke, lineWidth: 1)
        )
    }
}
