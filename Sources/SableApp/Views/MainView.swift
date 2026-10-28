import SableCore
import SwiftUI

/// Root of the utility window. The Modes | History | Settings switcher lives in
/// the AppKit toolbar (`MainWindowController`); this view routes the selected
/// tab, shows at most one slim banner above it, and hosts the one-time ChatGPT
/// welcome sheet whichever tab is open.
struct MainView: View {
    @EnvironmentObject private var model: MainWindowModel
    /// View-local preference: the ChatGPT invite never comes back once closed.
    @AppStorage("sable.dismissedChatGPTInvite") private var dismissedChatGPTInvite = false
    /// System Settings changes can't be observed, so permissions are re-read
    /// while the window is up.
    private let permissionPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            banner
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(Theme.Palette.windowBackground)
        .onAppear { model.onRefreshPermissions?() }
        .onReceive(permissionPoll) { _ in model.onRefreshPermissions?() }
        .sheet(isPresented: $model.showsChatGPTWelcome) {
            ChatGPTWelcomeSheet { model.showsChatGPTWelcome = false }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .modes: ModesPane()
        case .history: HistoryPane()
        case .settings: SettingsPane()
        }
    }

    // MARK: Banner

    /// Accessibility outranks the invite: without it Sable can't read a
    /// selection at all.
    @ViewBuilder
    private var banner: some View {
        if !model.accessibilityOK {
            Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.Palette.warn) {
                Text("Sable needs Accessibility to read your selection.")
            } actions: {
                Button("Grant…") { model.onOpenSystemSettings?(.accessibility) }
            }
        } else if showsChatGPTInvite {
            Banner(symbol: "sparkles", tint: Theme.Accent.ink) {
                Text("Use your ChatGPT plan in Sable")
            } actions: {
                Button("Continue with ChatGPT") {
                    model.section = .settings
                    model.connectChatGPT()
                }
                Button {
                    dismissedChatGPTInvite = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Don't show again")
            }
        }
    }

    /// "Invite existing users" from the plan-usage guidelines: only for someone
    /// still on the CLI with no ChatGPT account, and never on the Settings tab,
    /// which already offers the same button.
    private var showsChatGPTInvite: Bool {
        !dismissedChatGPTInvite
            && model.section != .settings
            && model.settings.generation.provider == .legacyCLI
            && model.connectionStatus.activeAccount == nil
            && !model.connectionStatus.isSigningIn
            && model.connectionActivity == .idle
    }
}

/// One-line notice strip above the tab content.
private struct Banner<Message: View, Actions: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder var message: Message
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                message
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 8)
                actions
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(tint.opacity(0.08))
            Divider()
        }
    }
}

/// Shown once, after the first sign-in with plan usage enabled. The copy
/// follows the plan-usage guidelines; Sable has no subscription of its own.
private struct ChatGPTWelcomeSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're using your ChatGPT plan")
                .font(.system(size: 15, weight: .semibold))
            Text("Eligible rewrites in Sable use your ChatGPT plan. Sable has no subscription of its own. You can manage usage in ChatGPT settings.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("Manage usage", destination: ChatGPTLinks.manageUsage)
                Spacer()
                Button("Got it", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 380)
    }
}
