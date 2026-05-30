import Foundation
import SableCore

/// Snapshot of Sable's operational health shown in the status strip.
struct DashboardStatus: Equatable {
    var configLoaded: Bool
    var configDetail: String
    var accessibilityOK: Bool
    var screenRecordingOK: Bool
    var currentRun: String

    static let placeholder = DashboardStatus(
        configLoaded: false,
        configDetail: "Loading…",
        accessibilityOK: false,
        screenRecordingOK: false,
        currentRun: "Idle"
    )
}

/// Observable backing store for the SwiftUI dashboard. `MainWindowController`
/// pushes records and status into this; the views react. Action callbacks are
/// owned by `AppCoordinator`.
@MainActor
final class MainWindowModel: ObservableObject {
    @Published var records: [RunRecord] = []
    @Published var status: DashboardStatus = .placeholder
    @Published var runtimeSettings = RuntimeSettings()
    @Published var runtimeSettingsURL: URL?
    @Published var selectedID: RunRecord.ID?

    var onReloadConfig: (() -> Void)?
    var onShowPermissions: (() -> Void)?
    var onClearHistory: (() -> Void)?
    var onCopyOutput: ((RunRecord) -> Void)?
    var onSaveRuntimeSettings: ((RuntimeSettings) -> Void)?

    var selectedRecord: RunRecord? {
        guard let selectedID, let match = records.first(where: { $0.id == selectedID }) else {
            return records.first
        }
        return match
    }

    /// Replaces history while preserving the user's current selection when that
    /// run still exists, otherwise falling back to the newest run.
    func setRecords(_ records: [RunRecord]) {
        self.records = records
        if selectedID == nil || !records.contains(where: { $0.id == selectedID }) {
            selectedID = records.first?.id
        }
    }

    func copySelectedOutput() {
        guard let record = selectedRecord else { return }
        onCopyOutput?(record)
    }

    func setRuntimeSettings(_ settings: RuntimeSettings, url: URL) {
        runtimeSettings = settings
        runtimeSettingsURL = url
    }

    func saveRuntimeSettings(claudePath: String, codexPath: String) {
        onSaveRuntimeSettings?(RuntimeSettings(claudePath: claudePath, codexPath: codexPath))
    }
}
