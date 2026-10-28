import AppKit
import KeyboardShortcuts
import SableCore
import SwiftUI

/// Settings tab: one grouped form. Edits bind straight to `model.settings`
/// (autosaved). Connection and key actions go through `MainWindowModel`'s
/// helpers; nothing here holds an existing credential, and no action switches
/// the provider on the user's behalf.
struct SettingsPane: View {
    @EnvironmentObject private var model: MainWindowModel
    @State private var showsAdvanced = false

    var body: some View {
        Form {
            if !model.accessibilityOK {
                Section("Permissions") {
                    LabeledContent {
                        PermissionStatus(granted: false) { model.onOpenSystemSettings?(.accessibility) }
                    } label: {
                        Text("Accessibility")
                        Text("Required to read your selection in other apps.")
                    }
                }
            }

            ChatGPTSection()
            rewritingSection
            shortcutsSection

            Section {
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    advancedRows
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Rewriting

    private var rewritingSection: some View {
        Section("Rewriting") {
            Picker("Provider", selection: Binding(
                get: { model.settings.generation.provider },
                set: { model.settings.generation = model.settings.generation.selectingProvider($0) }
            )) {
                ForEach(GenerationProvider.settingsOrder, id: \.self) { provider in
                    Text(provider.settingsTitle).tag(provider)
                }
            }

            switch model.settings.generation.provider {
            case .chatGPT:
                ChatGPTModelPicker(selection: $model.settings.generation.model, defaultTitle: "Automatic")
            case .openRouter:
                OpenRouterKeyRow()
                OpenRouterModelField(selection: $model.settings.generation.model)
            case .legacyCLI:
                Text("Each mode uses its own CLI and model, set in Modes.")
                    .foregroundStyle(.secondary)
            }

            Picker(selection: $model.settings.resultHandling) {
                ForEach(ResultHandling.allCases, id: \.self) { handling in
                    Text(handling.title).tag(handling)
                }
            } label: {
                Text("After a rewrite")
                Text(resultHandlingHint)
            }
            .pickerStyle(.radioGroup)
        }
    }

    /// `y` yanks stay inside the review editor; only ⌘C, ⏎ and ⌘⏎ reach the
    /// system clipboard. Say so, because Vim users expect `y` to copy.
    private var resultHandlingHint: String {
        switch model.settings.resultHandling {
        case .review:
            return "⏎ copies, ⌘⏎ pastes back into the app you came from. y yanks inside the editor only; ⌘C copies a selection."
        case .quickCopy:
            return "The result goes to the clipboard as soon as it's ready."
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        Section("Shortcuts") {
            LabeledContent {
                HotkeyRecorder(name: .sablePopup)
            } label: {
                Text("Mode picker")
                Text("Opens the picker for the current selection, from any app.")
            }
            Picker("Picker starts on", selection: Binding(
                get: { model.settings.defaultMode?.id ?? UUID() },
                set: { model.settings.defaultModeID = $0 }
            )) {
                ForEach(model.settings.modes) { mode in
                    Text(mode.name).tag(mode.id)
                }
            }
        }
    }

    // MARK: Advanced

    @ViewBuilder
    private var advancedRows: some View {
        Toggle(isOn: $model.settings.attachesScreenshotsForCLI) {
            Text("Screenshots for CLI runs")
            Text("Attach a screenshot for visual context. ChatGPT and OpenRouter never capture the screen.")
        }
        if model.settings.attachesScreenshotsForCLI {
            LabeledContent("Screen Recording") {
                PermissionStatus(granted: model.screenRecordingOK) { model.onOpenSystemSettings?(.screenRecording) }
            }
        }
        if model.accessibilityOK {
            LabeledContent("Accessibility") {
                PermissionStatus(granted: true) { model.onOpenSystemSettings?(.accessibility) }
            }
        }

        pathField("Claude Code path", text: $model.settings.runtimePaths.claudePath)
        pathField("Codex CLI path", text: $model.settings.runtimePaths.codexPath)
        LabeledContent("Working directory") {
            HStack(spacing: 6) {
                TextField("Working directory", text: $model.settings.cwd, prompt: Text("~"))
                    .labelsHidden()
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 200)
                Button("Choose…", action: chooseDirectory)
            }
        }
        LabeledContent("Timeout") {
            HStack(spacing: 6) {
                Text("\(Int(model.settings.timeoutSeconds)) s")
                    .monospacedDigit()
                Stepper("Timeout", value: $model.settings.timeoutSeconds, in: 15...600, step: 15)
                    .labelsHidden()
            }
        }
        if let url = model.settingsURL {
            LabeledContent {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: {
                Text("Settings file")
                Text(url.path).truncationMode(.middle)
            }
        }
    }

    private func pathField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text("Search PATH"))
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 280)
        }
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

// MARK: - ChatGPT

/// The ChatGPT connection section. Copy follows the plan-usage guidelines. Each
/// action starts a sign-in through the coordinator; the section only renders
/// what `connectionStatus` reports, so a failed or cancelled sign-in leaves the
/// previous account (or the signed-out state) on screen with a notice.
private struct ChatGPTSection: View {
    @EnvironmentObject private var model: MainWindowModel

    var body: some View {
        let state = ChatGPTConnectionPresentation(
            status: model.connectionStatus,
            activity: model.connectionActivity,
            issue: model.connectionIssue
        )

        Section("ChatGPT") {
            switch state.phase {
            case .signedOut:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use your ChatGPT plan")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Complete eligible rewrites in Sable with usage included in your ChatGPT plan or credits balance. Sable has no subscription of its own.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ContinueWithChatGPTButton(title: "Continue with ChatGPT") { model.connectChatGPT() }
                        .padding(.top, 2)
                }
                .padding(.vertical, 4)

            case .signingIn:
                if let account = state.account {
                    AccountRow(account: account)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish connecting in your browser.")
                    Spacer()
                    Button("Cancel") { model.cancelChatGPTSignIn() }
                }

            case .disconnecting:
                if let account = state.account {
                    AccountRow(account: account)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Disconnecting…").foregroundStyle(.secondary)
                }

            case .connected:
                if let account = state.account {
                    AccountRow(account: account, connected: true) { model.disconnectChatGPT() }
                }
                HStack(spacing: 4) {
                    Text("Using ChatGPT plan ·").foregroundStyle(.secondary)
                    Link("Manage usage", destination: ChatGPTLinks.manageUsage)
                }

            case .usageSharingOff:
                if let account = state.account {
                    AccountRow(account: account) { model.disconnectChatGPT() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("You're signed in with ChatGPT")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Usage sharing is off. Enable it to use your ChatGPT plan in Sable.")
                        .foregroundStyle(.secondary)
                    Button("Enable usage sharing") { model.connectChatGPT() }
                        .padding(.top, 2)
                }
                .padding(.vertical, 2)

            case .reconnectRequired:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reconnect to ChatGPT")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Your connection needs to be renewed before Sable can use ChatGPT again.")
                        .foregroundStyle(.secondary)
                    ContinueWithChatGPTButton(title: "Reconnect to ChatGPT") { model.connectChatGPT() }
                        .padding(.top, 2)
                }
                .padding(.vertical, 2)
            }

            if let notice = state.notice {
                NoticeRow(notice: notice, hasAccount: state.account != nil) { model.connectChatGPT() }
            }
        }
    }
}

/// Signed-in identity. Shows the display name and, when it differs, the email.
private struct AccountRow: View {
    let account: ConnectionAccount
    var connected = false
    var onDisconnect: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName)
                    .font(.system(size: 13, weight: .medium))
                if let email = account.email, email != account.displayName {
                    Text(email).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if connected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.ok)
            }
            if let onDisconnect {
                Button("Disconnect", action: onDisconnect)
            }
        }
    }
}

/// The latest nonsecret connection problem. A failed sign-in offers Try again;
/// it never changes the provider or the account that's still connected.
private struct NoticeRow: View {
    let notice: ChatGPTConnectionPresentation.Notice
    let hasAccount: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.warn)
            VStack(alignment: .leading, spacing: 4) {
                switch notice {
                case .signInFailed(let message):
                    Text("Couldn't connect to ChatGPT")
                        .font(.system(size: 13, weight: .semibold))
                    Text(message)
                        .foregroundStyle(.secondary)
                    Text(hasAccount
                         ? "Your current connection is unchanged."
                         : "Your provider choice is unchanged.")
                        .foregroundStyle(.secondary)
                    Button("Try again", action: onRetry)
                        .padding(.top, 2)
                case .remoteSignOutUnconfirmed:
                    Text("Signed out on this Mac. Sable couldn't confirm the sign-out with ChatGPT; you can disconnect Sable in ChatGPT settings.")
                        .foregroundStyle(.secondary)
                    Link("ChatGPT settings", destination: ChatGPTLinks.manageUsage)
                case .disconnectFailed(let message):
                    Text("Couldn't disconnect")
                        .font(.system(size: 13, weight: .semibold))
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Text-only "Continue with ChatGPT": black in light mode, white in dark, as
/// the guidelines ask. No logo is drawn; Sable doesn't bundle the official
/// mark, and an approximation would misrepresent it.
private struct ContinueWithChatGPTButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(InvertedButtonStyle())
    }
}

private struct InvertedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.adaptive(light: .white, dark: .black))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.adaptive(light: .black, dark: .white))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

// MARK: - OpenRouter key

/// Key entry. A new key lives only in this view's `draft` until it's handed to
/// `submitOpenRouterKey`, then the draft is cleared, and also cleared when the
/// row goes away. The saved key is never loaded back: once saved, the row shows
/// only that a key exists, with Replace and Remove.
private struct OpenRouterKeyRow: View {
    @EnvironmentObject private var model: MainWindowModel
    @State private var draft = ""
    @State private var isReplacing = false
    @State private var confirmsRemoval = false

    var body: some View {
        LabeledContent {
            if model.hasOpenRouterKey && !isReplacing {
                HStack(spacing: 8) {
                    Label("Key saved", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Theme.Palette.ok)
                    Button("Replace") { isReplacing = true }
                    Button("Remove") { confirmsRemoval = true }
                }
            } else {
                HStack(spacing: 6) {
                    SecureField("API key", text: $draft, prompt: Text("sk-or-…"))
                        .labelsHidden()
                        .frame(width: 200)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if isReplacing {
                        Button("Cancel") {
                            draft = ""
                            isReplacing = false
                        }
                    }
                }
            }
        } label: {
            Text("API key")
            if let issue = model.openRouterKeyIssue {
                Text(issue).foregroundStyle(Theme.Palette.error)
            } else {
                Text("Stored in a private file in ~/.config/sable.")
            }
        }
        .onDisappear {
            draft = ""
            isReplacing = false
        }
        .confirmationDialog("Remove the OpenRouter key?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) { model.removeOpenRouterKey() }
        } message: {
            Text("OpenRouter rewrites stop working until you add a key again.")
        }
    }

    private func save() {
        guard model.submitOpenRouterKey(draft) else { return }
        draft = ""
        isReplacing = false
    }
}
