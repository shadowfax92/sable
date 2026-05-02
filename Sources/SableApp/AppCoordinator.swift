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
    }

    private let configStore = ConfigStore()
    private let hotkeys = HotkeyService()
    private let statusMenu = StatusMenuController()
    private let promptPanel = PromptPanelController()
    private let notifications = UserNotificationClient()
    private var permissionsWindow: PermissionsWindowController?
    private var config: AppConfig?

    /// Starts menu, hotkey, permission, and cleanup services for the background app.
    func start() {
        notifications.requestAuthorization()
        try? RunTempDirectory.deleteStaleRuns()

        statusMenu.onReloadConfig = { [weak self] in self?.loadConfigAndHotkeys() }
        statusMenu.onShowPermissions = { [weak self] in self?.showPermissions() }
        hotkeys.onQuickFix = { [weak self] in self?.runQuickFix() }
        hotkeys.onAskClaude = { [weak self] in self?.runAskClaude() }

        loadConfigAndHotkeys()
        if !hasRequiredCapturePermissions(prompt: false) {
            showPermissions()
        }
    }

    func stop() {}

    private func loadConfigAndHotkeys() {
        do {
            let loaded = try configStore.load()
            config = loaded
            try hotkeys.configure(with: loaded)
            notifications.send(title: "Sable config loaded")
        } catch {
            notifications.send(title: "Sable config failed", body: error.localizedDescription)
        }
    }

    private func runQuickFix() {
        guard let config else {
            notifications.send(title: "Sable config missing")
            return
        }
        guard hasRequiredCapturePermissions(prompt: true) else {
            showPermissions()
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let context = try await prepareRunContext()
                finishRun(instruction: config.prompts.quickFix, context: context, config: config)
            } catch {
                notifications.send(title: "Sable failed", body: error.localizedDescription)
            }
        }
    }

    private func runAskClaude() {
        guard let config else {
            notifications.send(title: "Sable config missing")
            return
        }
        guard hasRequiredCapturePermissions(prompt: true) else {
            showPermissions()
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let context = try await prepareRunContext()
                promptPanel.showNearMouse { [weak self] instruction in
                    guard let self else {
                        context.selection.clipboardSnapshot?.restore()
                        try? context.runDirectory.delete()
                        return
                    }

                    guard let instruction else {
                        context.selection.clipboardSnapshot?.restore()
                        try? context.runDirectory.delete()
                        return
                    }

                    finishRun(instruction: instruction, context: context, config: config)
                }
            } catch {
                notifications.send(title: "Sable failed", body: error.localizedDescription)
            }
        }
    }

    private func prepareRunContext() async throws -> RunContext {
        let directory = try RunTempDirectory()
        var selection: SelectionCapture.Result?

        do {
            let capturedSelection = try await SelectionCapture().capture()
            selection = capturedSelection
            try ScreenshotCapture().capture(to: directory.screenshotURL)
            return RunContext(runDirectory: directory, selection: capturedSelection)
        } catch {
            selection?.clipboardSnapshot?.restore()
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
                let output = try await ClaudeRunner().run(
                    ClaudeRunner.Request(
                        command: config.claude.command,
                        args: config.claude.args,
                        cwd: expandHome(config.claude.cwd),
                        timeoutSeconds: config.claude.timeoutSeconds,
                        prompt: prompt
                    )
                )

                ClipboardWriter().write(output)
                notifications.send(title: "Copied edited text")
                try? context.runDirectory.delete()
            } catch {
                context.selection.clipboardSnapshot?.restore()
                notifications.send(title: "Sable failed", body: error.localizedDescription)
                try? context.runDirectory.delete()
            }
        }
    }

    private func showPermissions() {
        if permissionsWindow == nil {
            permissionsWindow = PermissionsWindowController()
        }
        permissionsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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
