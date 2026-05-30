import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SableCore

/// Glue between global hotkeys, the floating popup, the CLI runtimes, and the
/// main window. Owns the app's live `SableSettings` and the lifecycle of a single
/// in-flight run (so Escape can cancel it).
@MainActor
final class AppCoordinator {
    /// Everything captured before the popup runs: the selection, the clipboard
    /// snapshot to restore on cancel/fail, and the best-effort screenshot.
    private struct PendingContext {
        var text: String
        var snapshot: ClipboardSnapshot?
        var runDirectory: RunTempDirectory?
        var screenshotPath: String?
    }

    private let settingsStore = SableSettingsStore()
    private let historyStore = RunHistoryStore()
    private let hotkeys = HotkeyService()
    private let mainWindow = MainWindowController()
    private let overlay = OverlayPanelController()
    private let notifications = UserNotificationClient()

    private var settings = SableSettings.standard
    private var records: [RunRecord] = []

    private var pendingContext: PendingContext?
    private var activeMode: SableMode?
    private var activeRecord: RunRecord?
    private var currentRunTask: Task<Void, Never>?

    /// Boots services: loads settings + history, wires callbacks, registers hotkeys.
    func start() {
        notifications.requestAuthorization()
        try? RunTempDirectory.deleteStaleRuns()

        settings = (try? settingsStore.load()) ?? .standard
        records = (try? historyStore.load()) ?? []

        let model = mainWindow.model
        model.applyLoadedSettings(settings)
        model.settingsURL = settingsStore.settingsURL
        model.setRecords(records)

        model.onSaveSettings = { [weak self] in self?.saveSettings($0) }
        model.onClearHistory = { [weak self] in self?.clearHistory() }
        model.onCopyOutput = { [weak self] in self?.copyOutput(from: $0) }
        model.onRefreshPermissions = { [weak self] in self?.refreshPermissions() }
        model.onOpenSystemSettings = { [weak self] in self?.openSystemSettings($0) }
        model.onRunMode = { [weak self] in self?.triggerMode(id: $0) }

        overlay.model.onSubmit = { [weak self] in self?.runActive(input: $0) }
        overlay.model.onCancel = { [weak self] in self?.cancelActive() }
        overlay.model.onPickMode = { [weak self] in self?.switchMode(to: $0) }

        hotkeys.onOpenPopup = { [weak self] in self?.openPopup() }
        hotkeys.onTriggerMode = { [weak self] in self?.triggerMode(id: $0) }
        hotkeys.syncModeHotkeys(settings.modes)
        hotkeys.seedDefaultsIfNeeded()

        refreshPermissions()
        showMainWindow()
    }

    func stop() {
        currentRunTask?.cancel()
    }

    func showMainWindow() {
        refreshPermissions()
        mainWindow.show()
    }

    // MARK: - Triggering a run

    private func openPopup() {
        guard let mode = settings.defaultMode else { return }
        beginInteraction(mode: mode)
    }

    private func triggerMode(id: UUID) {
        guard let mode = settings.mode(withID: id) else { return }
        beginInteraction(mode: mode)
    }

    /// Captures the selection (while the user's app is still frontmost), then shows
    /// the popup. Instant modes run immediately; input modes wait for ⏎.
    private func beginInteraction(mode: SableMode) {
        resetInteraction()

        guard ensureAccessibility() else {
            showMainWindow()
            mainWindow.model.section = .settings
            return
        }

        Task { @MainActor in
            let context = await captureContext()
            pendingContext = context
            activeMode = mode
            overlay.present(mode: mode, selectedText: context.text, modes: settings.modes)
            if !mode.requiresInput {
                runActive(input: "")
            }
        }
    }

    private func captureContext() async -> PendingContext {
        var text = ""
        var snapshot: ClipboardSnapshot?
        if let result = try? await SelectionCapture().capture() {
            text = result.text
            snapshot = result.clipboardSnapshot
        }

        var runDirectory: RunTempDirectory?
        var screenshotPath: String?
        if let directory = try? RunTempDirectory() {
            runDirectory = directory
            if (try? ScreenshotCapture().capture(to: directory.screenshotURL)) != nil {
                screenshotPath = directory.screenshotURL.path
            }
        }

        return PendingContext(
            text: text,
            snapshot: snapshot,
            runDirectory: runDirectory,
            screenshotPath: screenshotPath
        )
    }

    private func switchMode(to id: UUID) {
        guard case .input = overlay.model.phase, let mode = settings.mode(withID: id) else { return }
        activeMode = mode
        overlay.model.configure(mode: mode, selectedText: pendingContext?.text ?? "", modes: settings.modes)
        if !mode.requiresInput {
            runActive(input: "")
        }
    }

    private func runActive(input: String) {
        guard let mode = activeMode, let context = pendingContext else { return }

        let instruction = effectiveInstruction(mode: mode, input: input)
        var record = RunRecord(
            id: UUID(),
            createdAt: Date(),
            completedAt: nil,
            status: .running,
            instruction: instruction.isEmpty ? mode.name : instruction,
            selectedText: context.text,
            screenshotPath: context.screenshotPath,
            outputText: nil,
            errorMessage: nil
        )
        activeRecord = record
        mainWindow.model.selectedRecordID = record.id
        persistAndDisplay(record)
        overlay.model.phase = .thinking
        updateStatus("Thinking")

        currentRunTask = Task { @MainActor in
            do {
                let prompt = PromptBuilder.build(
                    instruction: instruction,
                    selectedText: context.text,
                    screenshotPath: context.screenshotPath ?? ""
                )
                let output = try await RuntimeRunner().run(
                    RuntimeRunner.Request(
                        runtimeID: mode.runtimeID,
                        runtimeSettings: settings.runtimePaths,
                        cwd: expandHome(settings.cwd),
                        timeoutSeconds: settings.timeoutSeconds,
                        prompt: prompt,
                        model: mode.model
                    )
                )
                try Task.checkCancellation()

                ClipboardWriter().write(output)
                record.status = .copied
                record.completedAt = Date()
                record.outputText = output
                activeRecord = record
                persistAndDisplay(record)
                overlay.model.phase = .done(output)
                updateStatus("Copied")
                cleanup(context)
                clearActive()
                scheduleOverlayClose()
            } catch is CancellationError {
                // cancelActive() already handled cleanup and the record.
            } catch {
                context.snapshot?.restore()
                record.status = .failed
                record.completedAt = Date()
                record.errorMessage = error.localizedDescription
                activeRecord = record
                persistAndDisplay(record)
                overlay.model.phase = .error(error.localizedDescription)
                updateStatus("Failed")
                notifications.send(title: "Sable run failed", body: error.localizedDescription)
                cleanup(context)
                clearActive()
            }
        }
    }

    private func cancelActive() {
        let task = currentRunTask
        currentRunTask = nil
        task?.cancel()

        if let context = pendingContext {
            context.snapshot?.restore()
            cleanup(context)
        }
        if task != nil, var record = activeRecord, record.status == .running || record.status == .capturing {
            record.status = .cancelled
            record.completedAt = Date()
            persistAndDisplay(record)
        }

        overlay.close()
        updateStatus("Idle")
        clearActive()
    }

    private func effectiveInstruction(mode: SableMode, input: String) -> String {
        let base = mode.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return typed }
        if typed.isEmpty { return base }
        return base + "\n\nAdditional instruction: " + typed
    }

    private func scheduleOverlayClose() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if case .done = overlay.model.phase {
                overlay.close()
            }
        }
    }

    private func resetInteraction() {
        currentRunTask?.cancel()
        currentRunTask = nil
        if let context = pendingContext {
            context.snapshot?.restore()
            cleanup(context)
        }
        overlay.close()
        clearActive()
    }

    private func clearActive() {
        pendingContext = nil
        activeMode = nil
        activeRecord = nil
    }

    private func cleanup(_ context: PendingContext) {
        try? context.runDirectory?.delete()
    }

    // MARK: - History

    private func persistAndDisplay(_ record: RunRecord) {
        records = (try? historyStore.upsert(record)) ?? RunHistoryStore.upserting(
            record,
            into: records,
            maxRecords: 50
        )
        mainWindow.model.setRecords(records)
    }

    private func clearHistory() {
        try? historyStore.clear()
        records = []
        mainWindow.model.setRecords([])
        updateStatus("History cleared")
    }

    private func copyOutput(from record: RunRecord) {
        guard let output = record.outputText, !output.isEmpty else { return }
        ClipboardWriter().write(output)
        updateStatus("Copied")
    }

    // MARK: - Settings + permissions

    private func saveSettings(_ newSettings: SableSettings) {
        settings = newSettings
        try? settingsStore.save(newSettings)
        hotkeys.syncModeHotkeys(newSettings.modes)
    }

    private func refreshPermissions() {
        mainWindow.model.accessibilityOK = AXIsProcessTrusted()
        mainWindow.model.screenRecordingOK = CGPreflightScreenCaptureAccess()
    }

    private func openSystemSettings(_ kind: PermissionKind) {
        let raw: String
        switch kind {
        case .accessibility:
            raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
        if let url = URL(string: raw) {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateStatus(_ status: String) {
        mainWindow.model.currentRun = status
    }

    /// Checks (and prompts for) Accessibility, which the selection capture needs.
    private func ensureAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func expandHome(_ raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if trimmed.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }
}
