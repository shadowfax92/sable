import AppKit
import SableCore
import SwiftUI

/// Root dashboard: a health strip across the top, then a resizable
/// history-list / run-detail split, in the spirit of Riff and Codex.
struct MainView: View {
    @EnvironmentObject private var model: MainWindowModel
    @State private var showingRuntimeSettings = false

    var body: some View {
        VStack(spacing: 0) {
            StatusStrip(
                status: model.status,
                onReload: { model.onReloadConfig?() },
                onPermissions: { model.onShowPermissions?() },
                onClear: { model.onClearHistory?() },
                onRuntimeSettings: { showingRuntimeSettings = true }
            )
            Divider().overlay(Theme.Palette.separator)
            HSplitView {
                HistoryList(records: model.records, selectedID: $model.selectedID)
                    .frame(minWidth: 240, idealWidth: Theme.Metric.sidebarWidth, maxWidth: 380)
                RunDetail(record: model.selectedRecord, onCopy: { model.copySelectedOutput() })
                    .frame(minWidth: 440, maxWidth: .infinity)
            }
        }
        .background(Theme.Palette.windowBackground)
        .sheet(isPresented: $showingRuntimeSettings) {
            RuntimeSettingsSheet(
                settings: model.runtimeSettings,
                settingsURL: model.runtimeSettingsURL,
                onCancel: { showingRuntimeSettings = false },
                onSave: { claudePath, codexPath in
                    model.saveRuntimeSettings(claudePath: claudePath, codexPath: codexPath)
                    showingRuntimeSettings = false
                }
            )
        }
    }
}

// MARK: - Status strip

private struct StatusStrip: View {
    let status: DashboardStatus
    let onReload: () -> Void
    let onPermissions: () -> Void
    let onClear: () -> Void
    let onRuntimeSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HealthPill(
                ok: status.configLoaded,
                okLabel: "Config loaded",
                badLabel: "Config not loaded",
                symbol: "doc.text"
            )
            .help(status.configDetail)
            HealthPill(
                ok: status.accessibilityOK,
                okLabel: "Accessibility",
                badLabel: "Accessibility off",
                symbol: "accessibility"
            )
            HealthPill(
                ok: status.screenRecordingOK,
                okLabel: "Screen Recording",
                badLabel: "Screen Recording off",
                symbol: "camera.viewfinder"
            )

            Spacer(minLength: 12)

            RunBadge(text: status.currentRun)

            Divider().frame(height: 16).overlay(Theme.Palette.separator)

            Button(action: onRuntimeSettings) { Label("Runtime", systemImage: "terminal") }
                .help("Runtime paths")
            Button(action: onReload) { Label("Reload", systemImage: "arrow.clockwise") }
                .help("Reload config")
            Button(action: onPermissions) { Label("Permissions", systemImage: "lock.shield") }
                .help("Check permissions")
            Button(action: onClear) { Label("Clear", systemImage: "trash") }
                .help("Clear history")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.Palette.detailBackground)
    }
}

private struct RuntimeSettingsSheet: View {
    let settingsURL: URL?
    let onCancel: () -> Void
    let onSave: (String, String) -> Void
    @State private var claudePath: String
    @State private var codexPath: String

    init(
        settings: RuntimeSettings,
        settingsURL: URL?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, String) -> Void
    ) {
        self.settingsURL = settingsURL
        self.onCancel = onCancel
        self.onSave = onSave
        _claudePath = State(initialValue: settings.claudePath)
        _codexPath = State(initialValue: settings.codexPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Runtime Paths")
                .font(.system(size: 20, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                pathField(label: "Claude", placeholder: "claude", text: $claudePath)
                pathField(label: "Codex", placeholder: "codex", text: $codexPath)
            }

            if let settingsURL {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(settingsURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([settingsURL])
                    }
                    .controlSize(.small)
                }
            }

            Divider().overlay(Theme.Palette.separator)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(claudePath, codexPath)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.Palette.detailBackground)
    }

    private func pathField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.Palette.code)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rowCorner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metric.rowCorner, style: .continuous)
                        .stroke(Theme.Palette.codeStroke)
                )
        }
    }
}

private struct HealthPill: View {
    let ok: Bool
    let okLabel: String
    let badLabel: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
            Text(ok ? okLabel : badLabel)
                .font(.system(size: 12, weight: .medium))
            Circle()
                .fill(ok ? Theme.Palette.ok : Theme.Palette.warn)
                .frame(width: 7, height: 7)
        }
        .foregroundStyle(ok ? Color.primary : Theme.Palette.warn)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.Palette.chip)
        .clipShape(Capsule())
    }
}

private struct RunBadge: View {
    let text: String

    var body: some View {
        let visual = RunVisual.from(text)
        return HStack(spacing: 6) {
            if visual.busy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: visual.symbol)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(visual.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(visual.color.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - History list

private struct HistoryList: View {
    let records: [RunRecord]
    @Binding var selectedID: RunRecord.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("HISTORY")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(records.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if records.isEmpty {
                EmptyHistory()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(records) { record in
                            HistoryRow(record: record, isSelected: record.id == selectedID)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedID = record.id }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.sidebarBackground)
    }
}

private struct EmptyHistory: View {
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No runs yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Use a hotkey to capture text.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HistoryRow: View {
    let record: RunRecord
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: record.status.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(record.status.tint)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.instruction.isEmpty ? "(No instruction)" : record.instruction)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Self.time.string(from: record.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(record.status.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(record.status.tint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metric.rowCorner, style: .continuous)
                .fill(isSelected ? Theme.Palette.rowSelected : Color.clear)
        )
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Run detail

private struct RunDetail: View {
    let record: RunRecord?
    let onCopy: () -> Void

    var body: some View {
        Group {
            if let record {
                content(for: record)
            } else {
                EmptyDetail()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.detailBackground)
    }

    private func content(for record: RunRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(for: record)

                if let error = record.errorMessage, !error.isEmpty {
                    ErrorBanner(message: error)
                }

                section(title: "Selected text") {
                    CodeBlock(text: record.selectedText, minHeight: 120, placeholder: "Nothing captured")
                }

                section(title: "Output", accessory: {
                    Button(action: onCopy) { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled((record.outputText ?? "").isEmpty)
                }) {
                    CodeBlock(text: record.outputText ?? "", minHeight: 160, placeholder: "No output yet")
                }

                if let path = record.screenshotPath {
                    ScreenshotFooter(path: path)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(for record: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(record.instruction.isEmpty ? "(No instruction)" : record.instruction)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                StatusBadge(status: record.status)
            }
            Text(Self.timestamp.string(from: record.createdAt))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func section<Content: View, Accessory: View>(
        title: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            content()
        }
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Nothing selected")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Run a hotkey, then pick a run from the list to inspect it.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatusBadge: View {
    let status: RunStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(status.displayName)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(status.tint.opacity(0.12))
        .clipShape(Capsule())
    }
}

private struct CodeBlock: View {
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

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.error)
            Text(message)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.Palette.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.codeCorner, style: .continuous))
    }
}

private struct ScreenshotFooter: View {
    let path: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

// MARK: - Status visuals

private struct RunVisual {
    let color: Color
    let symbol: String
    let busy: Bool

    static func from(_ text: String) -> RunVisual {
        let lowered = text.lowercased()
        if lowered.contains("captur") || lowered.contains("running") {
            return RunVisual(color: Theme.Palette.running, symbol: "circle.dotted", busy: true)
        }
        if lowered.contains("copied") {
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

extension RunStatus {
    var tint: Color {
        switch self {
        case .capturing, .running:
            return Theme.Palette.running
        case .copied:
            return Theme.Palette.ok
        case .failed:
            return Theme.Palette.error
        case .cancelled:
            return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .capturing:
            return "camera.viewfinder"
        case .running:
            return "sparkles"
        case .copied:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled:
            return "slash.circle"
        }
    }
}
