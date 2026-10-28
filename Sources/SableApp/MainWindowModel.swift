import Combine
import Foundation
import SableCore

enum NavSection: String, CaseIterable, Identifiable {
    case home
    case modes
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .modes: return "Modes"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .modes: return "wand.and.stars"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
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
    @Published var section: NavSection = .home
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
    /// Set by the coordinator after the first sign-in that enables ChatGPT plan
    /// usage. Settings shows the one-time "You're using your ChatGPT plan" sheet,
    /// then clears this.
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
}
