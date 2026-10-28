import AppKit
import KeyboardShortcuts
import SableCore
import SwiftUI

/// Links the guidelines tell Sable to open for ChatGPT plan usage. The usage
/// page also manages connected apps, so it's the target for sign-out follow-up.
enum ChatGPTLinks {
    static let manageUsage = URL(string: "https://chatgpt.com/settings/usage")!
}

// MARK: - Runtime + model pickers

/// Claude / Codex harness picker. Switching harness resets the model to the CLI
/// default, since each harness has its own model namespace.
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
        .onChange(of: runtime) { _ in model = "default" }
    }
}

struct ModelPicker: View {
    let options: [RuntimeModelOption]
    @Binding var model: String

    var body: some View {
        Picker("", selection: $model) {
            ForEach(options) { option in
                Text(option.label).tag(option.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 200)
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

/// "Granted" / "Needed" plus the button that opens the matching System Settings
/// pane. Sable can't grant anything itself, so the button only navigates.
struct PermissionStatus: View {
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Palette.ok)
            } else {
                Label("Needed", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.Palette.warn)
                Button("Grant…", action: action)
            }
        }
        .labelStyle(.titleAndIcon)
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
    /// Active states share the running tint. Delivered results (copied, pasted)
    /// read as success; a discarded review is a deliberate choice, not an
    /// error, so it stays neutral like a cancel.
    var tint: Color {
        switch self {
        case .capturing, .running, .review: return Theme.Palette.running
        case .copied, .pasted: return Theme.Palette.ok
        case .failed: return Theme.Palette.error
        case .cancelled, .discarded: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .capturing: return "camera.viewfinder"
        case .running: return "sparkles"
        case .review: return "pencil.circle"
        case .copied: return "checkmark.circle.fill"
        case .pasted: return "doc.on.clipboard.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "slash.circle"
        case .discarded: return "xmark.circle"
        }
    }

    /// Drives the spinner. Review is active but waits on the user, not on work,
    /// so it never spins.
    var isBusy: Bool { self == .capturing || self == .running }
}

/// Read-only, selectable text on a quiet surface, used for history's Original
/// and Result. It doesn't scroll on its own; the enclosing detail view does, so
/// long rewrites never nest scroll views.
struct TextPanel: View {
    let text: String
    let placeholder: String

    var body: some View {
        Text(text.isEmpty ? placeholder : text)
            .font(.system(size: 13))
            .lineSpacing(2)
            .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.Palette.code)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.codeCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metric.codeCorner, style: .continuous)
                    .stroke(Theme.Palette.codeStroke, lineWidth: 1)
            )
    }
}
