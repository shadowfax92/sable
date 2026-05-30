import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SableCore

@MainActor
final class AppCoordinator {
    private struct RunContext {
        let runDirectory: RunTempDirectory
        let selection: SelectionCapture.Result
        let record: RunRecord
    }

    private let configStore = ConfigStore()
    private let historyStore = RunHistoryStore()
    private let hotkeys = HotkeyService()
    private let statusMenu = StatusMenuController()
    private let mainWindow = MainWindowController()
    private let promptPanel = PromptPanelController()
    private let notifications = UserNotificationClient()
    private var permissionsWindow: PermissionsWindowController?
    private var config: AppConfig?
    private var runtimeSettings = RuntimeSettings()
    private var records: [RunRecord] = []
    private var currentRunStatus = "Idle"

    /// Starts menu, hotkey, permission, and cleanup services for the background app.
    func start() {
        notifications.requestAuthorization()
        try? RunTempDirectory.deleteStaleRuns()
        records = (try? historyStore.load()) ?? []
        mainWindow.setRecords(records)

        statusMenu.onOpen = { [weak self] in self?.showMainWindow() }
        statusMenu.onReloadConfig = { [weak self] in self?.loadConfigAndHotkeys() }
        statusMenu.onShowPermissions = { [weak self] in self?.showPermissions() }
        statusMenu.onClearHistory = { [weak self] in self?.clearHistory() }
        mainWindow.onReloadConfig = { [weak self] in self?.loadConfigAndHotkeys() }
        mainWindow.onShowPermissions = { [weak self] in self?.showPermissions() }
        mainWindow.onClearHistory = { [weak self] in self?.clearHistory() }
        mainWindow.onCopyOutput = { [weak self] record in self?.copyOutput(from: record) }
        mainWindow.onSaveRuntimeSettings = { [weak self] settings in self?.saveRuntimeSettings(settings) }
        hotkeys.onQuickFix = { [weak self] in self?.runQuickFix() }
        hotkeys.onAskClaude = { [weak self] in self?.runAskRuntime() }

        loadConfigAndHotkeys()
        showMainWindow()
        if !hasRequiredCapturePermissions(prompt: false) {
            updateVisibleStatus(currentRun: "Permissions needed")
        }
    }

    func stop() {}

    private func loadConfigAndHotkeys() {
        do {
            let loaded = try configStore.load()
            config = loaded
            runtimeSettings = (try? configStore.readRuntimeSettings()) ?? RuntimeSettings()
            try hotkeys.configure(with: loaded)
            updateVisibleStatus(currentRun: currentRunStatus)
            notifications.send(title: "Sable config loaded")
        } catch {
            config = nil
            updateVisibleStatus(currentRun: "Config failed")
            notifications.send(title: "Sable config failed", body: error.localizedDescription)
        }
    }

    private func runQuickFix() {
        guard let config else {
            notifications.send(title: "Sable config missing")
            return
        }
        guard hasRequiredCapturePermissions(prompt: true) else {
            updateVisibleStatus(currentRun: "Permissions needed")
            showPermissions()
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let record = beginRun(instruction: config.prompts.quickFix)
                let context = try await prepareRunContext(record: record)
                finishRun(instruction: config.prompts.quickFix, context: context, config: config)
            } catch {
                notifications.send(title: "Sable failed", body: error.localizedDescription)
            }
        }
    }

    private func runAskRuntime() {
        guard let config else {
            notifications.send(title: "Sable config missing")
            return
        }
        guard hasRequiredCapturePermissions(prompt: true) else {
            updateVisibleStatus(currentRun: "Permissions needed")
            showPermissions()
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let record = beginRun(instruction: "Ask Sable")
                let context = try await prepareRunContext(record: record)
                promptPanel.showNearMouse { [weak self] instruction in
                    guard let self else {
                        context.selection.clipboardSnapshot?.restore()
                        try? context.runDirectory.delete()
                        return
                    }

                    guard let instruction else {
                        context.selection.clipboardSnapshot?.restore()
                        var cancelled = context.record
                        cancelled.status = .cancelled
                        cancelled.completedAt = Date()
                        persistAndDisplay(cancelled)
                        try? context.runDirectory.delete()
                        return
                    }

                    var updated = context.record
                    updated.instruction = instruction
                    updated.status = .running
                    persistAndDisplay(updated)
                    let updatedContext = RunContext(
                        runDirectory: context.runDirectory,
                        selection: context.selection,
                        record: updated
                    )
                    finishRun(instruction: instruction, context: updatedContext, config: config)
                }
            } catch {
                notifications.send(title: "Sable failed", body: error.localizedDescription)
            }
        }
    }

    private func beginRun(instruction: String) -> RunRecord {
        let record = RunRecord(
            id: UUID(),
            createdAt: Date(),
            completedAt: nil,
            status: .capturing,
            instruction: instruction,
            selectedText: "",
            screenshotPath: nil,
            outputText: nil,
            errorMessage: nil
        )
        persistAndDisplay(record)
        notifications.send(title: "Sable started", body: instruction)
        return record
    }

    private func prepareRunContext(record: RunRecord) async throws -> RunContext {
        let directory = try RunTempDirectory()
        var selection: SelectionCapture.Result?
        var updatedRecord = record

        do {
            let capturedSelection = try await SelectionCapture().capture()
            selection = capturedSelection
            try ScreenshotCapture().capture(to: directory.screenshotURL)
            updatedRecord.selectedText = capturedSelection.text
            updatedRecord.screenshotPath = directory.screenshotURL.path
            updatedRecord.status = .running
            persistAndDisplay(updatedRecord)
            return RunContext(runDirectory: directory, selection: capturedSelection, record: updatedRecord)
        } catch {
            selection?.clipboardSnapshot?.restore()
            updatedRecord.status = .failed
            updatedRecord.completedAt = Date()
            updatedRecord.errorMessage = error.localizedDescription
            persistAndDisplay(updatedRecord)
            try? directory.delete()
            throw error
        }
    }

    private func finishRun(instruction: String, context: RunContext, config: AppConfig) {
        Task { [weak self] in
            guard let self else {
                context.selection.clipboardSnapshot?.restore()
                try? context.runDirectory.delete()
                return
            }

            do {
                let prompt = PromptBuilder.build(
                    instruction: instruction,
                    selectedText: context.selection.text,
                    screenshotPath: context.runDirectory.screenshotURL.path
                )
                let output = try await RuntimeRunner().run(
                    RuntimeRunner.Request(
                        runtimeID: config.runtime.id,
                        runtimeSettings: runtimeSettings,
                        cwd: expandHome(config.runtime.cwd),
                        timeoutSeconds: config.runtime.timeoutSeconds,
                        prompt: prompt
                    )
                )

                var copied = context.record
                copied.status = .copied
                copied.completedAt = Date()
                copied.outputText = output
                persistAndDisplay(copied)
                ClipboardWriter().write(output)
                notifications.send(title: "Copied edited text")
                try? context.runDirectory.delete()
            } catch {
                context.selection.clipboardSnapshot?.restore()
                var failed = context.record
                failed.status = .failed
                failed.completedAt = Date()
                failed.errorMessage = error.localizedDescription
                persistAndDisplay(failed)
                notifications.send(title: "Sable failed", body: error.localizedDescription)
                try? context.runDirectory.delete()
            }
        }
    }

    private func showPermissions() {
        showMainWindow()
        if permissionsWindow == nil {
            permissionsWindow = PermissionsWindowController()
        }
        permissionsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showMainWindow() {
        updateVisibleStatus(currentRun: currentRunStatus)
        mainWindow.show()
    }

    private func clearHistory() {
        try? historyStore.clear()
        records = []
        mainWindow.setRecords([])
        updateVisibleStatus(currentRun: "History cleared")
    }

    private func copyOutput(from record: RunRecord) {
        guard let output = record.outputText, !output.isEmpty else {
            return
        }
        ClipboardWriter().write(output)
        notifications.send(title: "Copied history output")
        updateVisibleStatus(currentRun: "Copied history output")
    }

    private func persistAndDisplay(_ record: RunRecord) {
        records = (try? historyStore.upsert(record)) ?? RunHistoryStore.upserting(
            record,
            into: records,
            maxRecords: 50
        )
        mainWindow.setRecords(records)
        updateVisibleStatus(currentRun: record.status.displayName)
    }

    private func updateVisibleStatus(currentRun: String) {
        currentRunStatus = currentRun
        statusMenu.setState(currentRun)
        mainWindow.setStatus(
            DashboardStatus(
                configLoaded: config != nil,
                configDetail: configDetail(),
                accessibilityOK: AXIsProcessTrusted(),
                screenRecordingOK: CGPreflightScreenCaptureAccess(),
                currentRun: currentRun
            )
        )
        mainWindow.setRuntimeSettings(runtimeSettings, url: configStore.runtimeSettingsURL)
    }

    private func saveRuntimeSettings(_ settings: RuntimeSettings) {
        do {
            try configStore.writeRuntimeSettings(settings)
            runtimeSettings = settings
            updateVisibleStatus(currentRun: currentRunStatus)
            notifications.send(title: "Sable runtime paths saved")
        } catch {
            notifications.send(title: "Sable runtime paths failed", body: error.localizedDescription)
        }
    }

    private func configDetail() -> String {
        guard let config else {
            return "Not loaded"
        }
        let runtime = RuntimeDefinitions.definition(for: config.runtime.id).displayName
        return "\(runtime), \(ConfigStore.defaultConfigURL().path)"
    }

    private func hasRequiredCapturePermissions(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let hasAccessibility = AXIsProcessTrustedWithOptions(options)
        let hasScreenRecording = CGPreflightScreenCaptureAccess() || (prompt && CGRequestScreenCaptureAccess())
        return hasAccessibility && hasScreenRecording
    }

    private func expandHome(_ raw: String) -> URL {
        if raw == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if raw.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(raw.dropFirst(2)))
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }
}
