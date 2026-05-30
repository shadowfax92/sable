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

/// Observable backing store for the SwiftUI window. `settings` is the live,
/// editable source of truth — edits anywhere in the UI mutate it and are
/// auto-saved (debounced) through `onSaveSettings`. `AppCoordinator` owns the
/// action callbacks and pushes records / permission state in.
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

    var onSaveSettings: ((SableSettings) -> Void)?
    var onRunMode: ((UUID) -> Void)?
    var onClearHistory: (() -> Void)?
    var onCopyOutput: ((RunRecord) -> Void)?
    var onRefreshPermissions: (() -> Void)?
    var onOpenSystemSettings: ((PermissionKind) -> Void)?

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
