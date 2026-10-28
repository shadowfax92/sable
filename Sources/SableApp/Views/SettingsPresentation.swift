import Foundation
import SableCore

// Pure view-state derivations for the Settings and Modes tabs. They hold the
// rules that are easy to get subtly wrong (connection precedence, provider/model
// namespaces, legacy-field preservation), so they're kept out of SwiftUI bodies
// and tested headlessly.

// MARK: - ChatGPT connection

/// What the ChatGPT section shows, derived from the state the coordinator pushes
/// into `MainWindowModel`. Never invents states the connection didn't report: a
/// failed sign-in leaves `phase` wherever `connectionStatus` says it is (signed
/// out, or still connected with the previous account) and only adds a notice.
struct ChatGPTConnectionPresentation: Equatable {
    enum Phase: Equatable {
        /// No account. Shows "Continue with ChatGPT".
        case signedOut
        /// A sign-in is waiting on the browser. A previous account, if any,
        /// stays active until the new identity is verified.
        case signingIn
        case disconnecting
        /// Signed in with plan scopes. Shows "Using ChatGPT plan · Manage usage".
        case connected
        /// Identity-only consent: signed in, but generation can't use the plan.
        case usageSharingOff
        /// The refresh grant was invalidated; the user has to sign in again.
        case reconnectRequired
    }

    enum Notice: Equatable {
        case signInFailed(String)
        case remoteSignOutUnconfirmed
        case disconnectFailed(String)
    }

    let phase: Phase
    let account: ConnectionAccount?
    let notice: Notice?

    init(status: ConnectionStatus, activity: ConnectionActivity, issue: ConnectionIssue?) {
        account = status.activeAccount
        // In-flight work wins: the UI sets `activity` before the coordinator has
        // re-read status, and `isSigningIn` covers a sign-in started elsewhere.
        if activity == .disconnecting {
            phase = .disconnecting
        } else if activity == .signingIn || status.isSigningIn {
            phase = .signingIn
        } else if status.needsReconnect {
            // Checked before the account: terminal invalidation clears the
            // active account but keeps the registration to reconnect.
            phase = .reconnectRequired
        } else if status.activeAccount == nil {
            phase = .signedOut
        } else if !status.planUsageEnabled {
            phase = .usageSharingOff
        } else {
            phase = .connected
        }

        switch issue {
        case .signInFailed(let message): notice = .signInFailed(message)
        case .remoteSignOutUnconfirmed: notice = .remoteSignOutUnconfirmed
        case .disconnectFailed(let message): notice = .disconnectFailed(message)
        case nil: notice = nil
        }
    }

    /// Only a plan-enabled connection can actually generate with ChatGPT, so
    /// the model menu is enabled only then.
    var canChooseModel: Bool { phase == .connected }
}

// MARK: - Providers and models

extension GenerationProvider {
    /// Settings menu order. Direct providers first; CLI harnesses are advanced.
    static let settingsOrder: [GenerationProvider] = [.chatGPT, .openRouter, .legacyCLI]

    var settingsTitle: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .openRouter: return "OpenRouter"
        case .legacyCLI: return "Claude Code or Codex CLI"
        }
    }

    /// Compact label for history metadata.
    var shortTitle: String {
        self == .legacyCLI ? "CLI" : settingsTitle
    }
}

extension GenerationSelection {
    /// The selection after the user explicitly picks `provider`. Model slugs
    /// belong to one provider's namespace (a ChatGPT slug is meaningless to
    /// OpenRouter), so a real change resets the model to that provider's default
    /// instead of carrying a slug across. Re-picking the same provider is a no-op.
    func selectingProvider(_ provider: GenerationProvider) -> GenerationSelection {
        provider == self.provider ? self : GenerationSelection(provider: provider)
    }
}

/// One row of a direct provider's model menu. A nil `slug` stores
/// `GenerationSelection.model == nil`, which lets the provider resolve its own
/// default (for ChatGPT, the first visible catalog model).
struct ModelMenuEntry: Equatable, Identifiable {
    let slug: String?
    let title: String

    var id: String { slug ?? "" }

    /// Menu rows for a catalog and the stored slug, in server order. A stored
    /// slug the loaded catalog doesn't list stays selectable as "(unavailable)"
    /// rather than being switched; generation then fails with a clear error. While
    /// the catalog isn't loaded, its availability is unknown, so no suffix.
    static func entries(
        catalog: ModelCatalogState,
        selected: String?,
        defaultTitle: String = "Automatic"
    ) -> [ModelMenuEntry] {
        var entries = [ModelMenuEntry(slug: nil, title: defaultTitle)]
        var listed: [GenerationModel] = []
        if case .loaded(let models) = catalog { listed = models }
        entries += listed.map { ModelMenuEntry(slug: $0.id, title: $0.displayName) }

        if let selected, !listed.contains(where: { $0.id == selected }) {
            let isLoaded: Bool
            if case .loaded = catalog { isLoaded = true } else { isLoaded = false }
            entries.append(ModelMenuEntry(slug: selected, title: isLoaded ? "\(selected) (unavailable)" : selected))
        }
        return entries
    }
}

// MARK: - Per-mode provider override

/// The Modes tab's provider menu. `.inherit` stores `mode.generation = nil`.
enum ModeProviderChoice: Hashable {
    case inherit
    case provider(GenerationProvider)

    init(_ mode: SableMode) {
        self = mode.generation.map { .provider($0.provider) } ?? .inherit
    }

    /// Applies the choice to `mode.generation` only. The legacy `runtimeID` and
    /// `model` are never read or cleared here: a direct provider must not use a
    /// CLI alias like "sonnet" as its model, and switching back to the CLI has
    /// to find the user's harness and model where they left them.
    func apply(to mode: inout SableMode) {
        switch self {
        case .inherit:
            mode.generation = nil
        case .provider(let provider):
            if mode.generation?.provider != provider {
                mode.generation = GenerationSelection(provider: provider)
            }
        }
    }
}
