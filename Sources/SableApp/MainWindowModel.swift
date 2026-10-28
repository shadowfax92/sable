import Combine
import Foundation
import SableCore

/// The utility window's three tabs, in segmented-control order. The order also
/// defines the ⌘1/⌘2/⌘3 menu shortcuts.
enum NavSection: String, CaseIterable, Identifiable {
    case modes
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modes: return "Modes"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }
}

extension Notification.Name {
    /// Main-menu request to show the utility window on a tab ("Settings… ⌘,",
    /// View ⌘1–⌘3). `object` is the `NavSection.rawValue`. `AppDelegate` posts
    /// it after asking the coordinator to show the window, and
    /// `MainWindowController` applies it to its model. A notification keeps the
    /// menu independent of the coordinator, which owns the window privately.
    static let sableShowSection = Notification.Name("sable.showSection")
}

enum PermissionKind {
    case accessibility
    case screenRecording
}

/// Connection work the user started from Settings and that is still running.
/// The UI sets it optimistically when the button is pressed, for instant feedback.
/// The interaction owner resets it to `.idle` when the operation ends.
/// `connectionStatus` stays authoritative for who is signed in.
enum ConnectionActivity: Equatable {
    case idle
    case signingIn
    case disconnecting
}

/// The latest connection problem worth showing in Settings. Messages are
/// user-facing and nonsecret: never tokens, authorization URLs or raw response
/// bodies. Cleared when the next connection operation starts.
enum ConnectionIssue: Equatable {
    /// Sign-in ended without a verified account. The previous account, if any,
    /// is still active.
    case signInFailed(String)
    /// Local credentials were cleared, but ChatGPT didn't confirm revocation.
    /// The user can disconnect Sable in ChatGPT settings.
    case remoteSignOutUnconfirmed
    case disconnectFailed(String)
}

/// Loading state of one provider's model catalog, in server order. Only direct
/// providers have catalogs; legacy CLI models keep using `modelOptions(for:)`.
enum ModelCatalogState: Equatable {
    case idle
    case loading
    case loaded([GenerationModel])
    case failed(String)
}

/// Observable backing store for the SwiftUI window. `settings` is the live,
/// editable source of truth — edits anywhere in the UI mutate it and are
/// auto-saved (debounced) through `onSaveSettings`. `AppCoordinator` owns the
/// action callbacks and pushes records / permission state in.
///
/// Connection, catalog and OpenRouter-key state follow the same push model.
/// Views call the synchronous `on…` callbacks. The coordinator runs the async
/// work and publishes nonsecret results back on the main actor. Secrets never
/// live here: a new OpenRouter key exists only in the entry view's local state
/// until it is handed to `onSaveOpenRouterKey`.
@MainActor
final class MainWindowModel: ObservableObject {
    @Published var section: NavSection = .modes
    @Published var settings: SableSettings
    @Published var records: [RunRecord] = []
    @Published var selectedRecordID: RunRecord.ID?
    @Published var accessibilityOK = false
    @Published var screenRecordingOK = false
    @Published var currentRun = "Idle"
    @Published var settingsURL: URL?
    /// Live Codex models from `codex debug models`; nil until detected (or if the
    /// CLI is unavailable), in which case the static fallback is used.
    @Published var detectedCodexModels: [RuntimeModelOption]?

    /// Nonsecret ChatGPT connection snapshot, re-read by the coordinator after
    /// every connection operation (the connection contract has no observation).
    @Published var connectionStatus = ConnectionStatus()
    @Published var connectionActivity: ConnectionActivity = .idle
    @Published var connectionIssue: ConnectionIssue?
    /// Per-provider model catalogs. Read through `modelCatalog(for:)`.
    @Published var modelCatalogs: [GenerationProvider: ModelCatalogState] = [:]
    /// Whether a protected OpenRouter key file exists. The key itself is never
    /// loaded into the UI.
    @Published var hasOpenRouterKey = false
    /// Nonsecret message from the last failed key save or removal.
    @Published var openRouterKeyIssue: String?
    /// Raised by the coordinator after the first sign-in that enables ChatGPT plan
    /// usage. The window shows the "You're using your ChatGPT plan" sheet while
    /// it's true, and its "Got it" button clears it. The coordinator owns the
    /// persisted once-ever flag; the view keeps no record of its own.
    @Published var showsChatGPTWelcome = false

    /// Model options to show for a harness: live Codex list when present, else the
    /// static catalog. Always includes the mode's current model so the picker
    /// never renders blank for a value the catalog doesn't list.
    func modelOptions(for runtime: RuntimeID, current: String) -> [RuntimeModelOption] {
        var options = (runtime == .codex ? detectedCodexModels : nil) ?? RuntimeDefinitions.models(for: runtime)
        if current != "default", !options.contains(where: { $0.id == current }) {
            options.append(RuntimeModelOption(id: current, label: current))
        }
        return options
    }

    var onSaveSettings: ((SableSettings) -> Void)?
    var onRunMode: ((UUID) -> Void)?
    var onClearHistory: (() -> Void)?
    var onCopyOutput: ((RunRecord) -> Void)?
    var onRefreshPermissions: (() -> Void)?
    var onOpenSystemSettings: ((PermissionKind) -> Void)?

    /// "Continue with ChatGPT". The coordinator opens the system browser through
    /// the connection's injected opener. Signing in never replaces the active
    /// account until the new identity is verified.
    var onConnectChatGPT: (() -> Void)?
    /// Cancels an in-flight sign-in. The active account is untouched.
    var onCancelChatGPTSignIn: (() -> Void)?
    var onDisconnectChatGPT: (() -> Void)?
    /// Reloads one direct provider's catalog after invalidating its cache.
    var onRefreshModels: ((GenerationProvider) -> Void)?
    /// Hands a newly entered key to protected storage. The view clears its local
    /// field immediately; success shows up as `hasOpenRouterKey`.
    var onSaveOpenRouterKey: ((ConnectionSecret) -> Void)?
    var onRemoveOpenRouterKey: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    init(settings: SableSettings = .standard) {
        self.settings = settings
        attachAutoSave()
    }

    /// Auto-saves shortly after the last edit, matching the inline-settings feel
    /// of the reference app rather than a modal Save button. `dropFirst` skips the
    /// current value so merely (re)subscribing never triggers a write.
    private func attachAutoSave() {
        cancellables.removeAll()
        $settings
            .dropFirst()
            .debounce(for: .seconds(0.4), scheduler: RunLoop.main)
            .sink { [weak self] settings in self?.onSaveSettings?(settings) }
            .store(in: &cancellables)
    }

    func modelCatalog(for provider: GenerationProvider) -> ModelCatalogState {
        modelCatalogs[provider] ?? .idle
    }

    var selectedRecord: RunRecord? {
        guard let selectedRecordID, let match = records.first(where: { $0.id == selectedRecordID }) else {
            return records.first
        }
        return match
    }

    /// Replaces history while preserving the user's selection when that run still
    /// exists, otherwise falling back to the newest run.
    func setRecords(_ records: [RunRecord]) {
        self.records = records
        if selectedRecordID == nil || !records.contains(where: { $0.id == selectedRecordID }) {
            selectedRecordID = records.first?.id
        }
    }

    /// Applies externally-loaded settings without retriggering a save: detaching
    /// first, then reattaching after assignment (the new subscription's
    /// `dropFirst` swallows the just-set value).
    func applyLoadedSettings(_ settings: SableSettings) {
        cancellables.removeAll()
        self.settings = settings
        attachAutoSave()
    }

    func copySelectedOutput() {
        guard let record = selectedRecord else { return }
        onCopyOutput?(record)
    }

    // MARK: - Connection actions
    //
    // Views call these instead of the raw callbacks. Each one does the optimistic
    // bookkeeping the contract assigns to the UI, then hands off. The coordinator
    // resets `connectionActivity` to `.idle`, re-reads `connectionStatus` and sets
    // `connectionIssue` when the async work ends.

    /// Continue with ChatGPT, and also Enable usage sharing, Reconnect and Try
    /// again: each is a fresh sign-in that requests plan scopes. It doesn't touch
    /// `settings.generation`; selecting ChatGPT after a successful grant is the
    /// coordinator's job, so a failed sign-in can't switch the provider.
    func connectChatGPT() {
        connectionIssue = nil
        connectionActivity = .signingIn
        onConnectChatGPT?()
    }

    func cancelChatGPTSignIn() {
        onCancelChatGPTSignIn?()
    }

    func disconnectChatGPT() {
        connectionIssue = nil
        connectionActivity = .disconnecting
        onDisconnectChatGPT?()
    }

    /// Hands a newly typed OpenRouter key to protected storage. Returns false,
    /// and does nothing, when the trimmed draft is empty. The caller owns the
    /// draft and must clear it after a true return; the key is never stored here.
    @discardableResult
    func submitOpenRouterKey(_ draft: String) -> Bool {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        openRouterKeyIssue = nil
        onSaveOpenRouterKey?(ConnectionSecret(key))
        return true
    }

    func removeOpenRouterKey() {
        openRouterKeyIssue = nil
        onRemoveOpenRouterKey?()
    }

    /// Asks for a catalog the window hasn't loaded yet. Explicit refreshes call
    /// `onRefreshModels` directly, because that also invalidates the cache.
    func requestModelCatalogIfNeeded(_ provider: GenerationProvider) {
        guard modelCatalog(for: provider) == .idle else { return }
        onRefreshModels?(provider)
    }
}
