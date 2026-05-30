import AppKit
import KeyboardShortcuts
import SableCore
import SwiftUI

struct SettingsPane: View {
    @EnvironmentObject private var model: MainWindowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: "Settings", subtitle: "Shortcuts, runtimes, and permissions.")

                generalCard
                permissionsCard
                runtimeCard
                footer
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: General

    private var generalCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: "General")
                FieldRow(title: "Quick popup shortcut", help: "Opens the popup with your default mode.") {
                    HotkeyRecorder(name: .sablePopup)
                }
                Divider().overlay(Theme.Palette.separator)
                FieldRow(title: "Default popup mode", help: "Which mode the quick popup starts with.") {
                    Picker("", selection: defaultModeBinding) {
                        ForEach(model.settings.modes) { mode in
                            Text(mode.name).tag(mode.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
        }
    }

    private var defaultModeBinding: Binding<UUID> {
        Binding(
            get: { model.settings.defaultModeID ?? model.settings.modes.first?.id ?? UUID() },
            set: { model.settings.defaultModeID = $0 }
        )
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: "Permissions")
                PermissionRow(
                    title: "Accessibility",
                    detail: "Required — lets Sable read the current selection.",
                    symbol: "accessibility",
                    granted: model.accessibilityOK,
                    action: { model.onOpenSystemSettings?(.accessibility) }
                )
                Divider().overlay(Theme.Palette.separator)
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Optional — adds a screenshot for visual context.",
                    symbol: "camera.viewfinder",
                    granted: model.screenRecordingOK,
                    action: { model.onOpenSystemSettings?(.screenRecording) }
                )
            }
        }
    }

    // MARK: Runtime

    private var runtimeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: "Runtimes")
                pathField(
                    title: "Claude Code path",
                    placeholder: "claude (leave blank to search PATH)",
                    text: $model.settings.runtimePaths.claudePath
                )
                Divider().overlay(Theme.Palette.separator)
                pathField(
                    title: "Codex CLI path",
                    placeholder: "codex (leave blank to search PATH)",
                    text: $model.settings.runtimePaths.codexPath
                )
                Divider().overlay(Theme.Palette.separator)
                FieldRow(title: "Working directory", help: "Where the CLI runs. Defaults to your home folder.") {
                    HStack(spacing: 8) {
                        TextField("~", text: $model.settings.cwd)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 220)
                        Button("Choose…", action: chooseDirectory)
                            .controlSize(.small)
                    }
                }
                Divider().overlay(Theme.Palette.separator)
                FieldRow(title: "Timeout", help: "Maximum time to wait for a run.") {
                    HStack(spacing: 8) {
                        Text("\(Int(model.settings.timeoutSeconds))s")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                        Stepper("", value: $model.settings.timeoutSeconds, in: 15...600, step: 15)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    private func pathField(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(model.settingsURL?.path ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let url = model.settingsURL {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.cwd = url.path
        }
    }
}
