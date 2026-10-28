import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import SableCore

/// Binds the UI to one interaction owner and shared provider services. Views emit
/// intent; generation IDs, credential operations and final delivery stay here or
/// behind injected core seams. Nothing starts OAuth until the user asks.
@MainActor
final class AppCoordinator {
    private enum Entry { case picker, mode(SableMode) }

    private let settingsStore = SableSettingsStore()
    private let historyStore = RunHistoryStore()
    private let hotkeys = HotkeyService()
    private let mainWindow = MainWindowController()
    private let overlay = OverlayPanelController()
    private let selectionCapture = SelectionCapture()
    private let connection: any ChatGPTConnecting
    private let keyStore: any OpenRouterKeyStore
    private let catalog: DirectGenerationModelCatalog
    private let generation: any TextGenerating
    private var settings = SableSettings.standard
    private var records: [RunRecord] = []
    private var activeMode: SableMode?
    private var entry: Entry = .picker
    private var selectedText = ""
    private var usesPill = false
    private var retryInput: String?
    private var lastInput = ""
    private var runProvider: GenerationProvider?
    private var allowsStartupWindow = true
    private var connectionTask: Task<Void, Never>?
    private var keyTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var catalogTasks: [GenerationProvider: Task<Void, Never>] = [:]
    private var catalogRevisions: [GenerationProvider: UUID] = [:]
    private var connectionRevision = UUID()
    private var keyRevision = UUID()
    private var providerChoiceRevision = UUID()
    private var settingsSubscription: AnyCancellable?

    init(connection: any ChatGPTConnecting = ChatGPTConnection(),
         keyStore: any OpenRouterKeyStore = FileOpenRouterKeyStore()) {
        self.connection = connection
        self.keyStore = keyStore
        let sharedCatalog = DirectGenerationModelCatalog(connection: connection, keyStore: keyStore)
        catalog = sharedCatalog
        generation = GenerationService(
            chatGPT: ChatGPTGenerationAdapter(connection: connection, catalog: sharedCatalog),
            openRouter: OpenRouterGenerationAdapter(keyStore: keyStore, catalog: sharedCatalog)
        )
    }

    /// Lazy construction wires effects without creating another framework around
    /// the coordinator. Core tests replace every native closure with a fake.
    private lazy var interaction: RewriteInteraction = {
        let capture = selectionCapture
        let owner = RewriteInteraction(
            generation: generation,
            capture: { source in
                // Ordering out a reused key panel needs one actor turn before AX
                // reads the source. The source is checked again before fallback.
                await Task.yield()
                do { return try await capture.capture(isSourceCurrent: source.isFrontmost).text }
                catch SableError.noSelectedText { return "" }
            },
            screenshot: {
                let directory = try RunTempDirectory()
                do {
                    try ScreenshotCapture().capture(to: directory.screenshotURL)
                    return InteractionAttachment(path: directory.screenshotURL.path) { try? directory.delete() }
                } catch {
                    try? directory.delete()
                    throw error
                }
            },
            writeClipboard: { ClipboardWriter().write($0) },
            clipboardRevision: { NSPasteboard.general.changeCount }
        )
        owner.onEvent = { [weak self] in self?.handle($0) }
        owner.onRecord = { [weak self] in self?.persistAndDisplay($0) }
        owner.onClose = { [weak self] id in
            guard let self else { return }
            overlay.close(interactionID: id)
            overlay.closeNotice(interactionID: id)
        }
        return owner
    }()

    func start() {
        try? RunTempDirectory.deleteStaleRuns()
        let hasSettings = FileManager.default.fileExists(atPath: settingsStore.settingsURL.path)
        settings = (try? settingsStore.load()) ?? .standard
        // Only genuinely new installs default to the now-concrete direct path.
        // Existing files retain their provider, custom modes, IDs and CLI values.
        if !hasSettings { settings.generation = GenerationSelection(provider: .chatGPT) }
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
        model.onConnectChatGPT = { [weak self] in self?.connectChatGPT() }
        model.onCancelChatGPTSignIn = { [weak self] in self?.cancelChatGPTSignIn() }
        model.onDisconnectChatGPT = { [weak self] in self?.disconnectChatGPT() }
        model.onRefreshModels = { [weak self] in self?.refreshModels($0) }
        model.onSaveOpenRouterKey = { [weak self] in self?.saveOpenRouterKey($0) }
        model.onRemoveOpenRouterKey = { [weak self] in self?.saveOpenRouterKey(nil) }
        // Observe provider intent immediately, before the UI's debounced disk
        // save. A sign-in completion must not overwrite a newer provider choice.
        settingsSubscription = model.$settings.map(\.generation).removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.providerChoiceRevision = UUID() }

        overlay.model.onSubmit = { [weak self] input in
            guard let self, overlay.currentInteractionID == interaction.interactionID else { return }
            runActive(input: input)
        }
        overlay.model.onCancel = { [weak self] in
            guard let self, overlay.currentInteractionID == interaction.interactionID else { return }
            cancelActive()
        }
        overlay.model.onPickMode = { [weak self] id in
            guard let self, overlay.currentInteractionID == interaction.interactionID else { return }
            switchMode(to: id)
        }
        overlay.model.onShowPicker = { [weak self] in
            guard let self, overlay.currentInteractionID == interaction.interactionID else { return }
            activeMode = nil
            overlay.showPicker()
        }
        overlay.model.onNoticeCancel = { [weak self] id in
            guard let self, interaction.interactionID == id else { return }
            cancelActive()
        }
        overlay.model.onFailureAction = { [weak self] action, id in self?.handleFailureAction(action, id: id) }
        overlay.model.onReviewDelivery = { [weak self] delivery in
            let action: InteractionAction
            switch delivery.action {
            case .copy: action = .copy
            case .paste: action = .paste
            case .discard: action = .discard
            }
            self?.interaction.deliver(id: delivery.interactionID, action: action, text: delivery.text)
        }
        hotkeys.onOpenPopup = { [weak self] in self?.openPopup() }
        hotkeys.onTriggerMode = { [weak self] in self?.triggerMode(id: $0) }
        hotkeys.syncModeHotkeys(settings.modes)
        hotkeys.seedDefaultsIfNeeded()
        refreshPermissions()
        if settings.generation.provider == .legacyCLI { detectCodexModels() }
        let revision = connectionRevision
        let initialKeyRevision = keyRevision
        startupTask = Task { [weak self] in
            guard let self else { return }
            let status = await connection.status()
            guard !Task.isCancelled else { return }
            if connectionRevision == revision { model.connectionStatus = status }
            let hasKey = (try? await keyStore.hasKey()) ?? false
            guard !Task.isCancelled else { return }
            if keyRevision == initialKeyRevision { model.hasOpenRouterKey = hasKey }
            // Routine startup stays quiet once setup is complete. No browser or
            // permission prompt is part of loading a saved connection.
            let provider = model.settings.generation.provider
            let connected = provider == .chatGPT ? status.planUsageEnabled && !status.needsReconnect
                : provider == .openRouter ? hasKey : true
            if allowsStartupWindow, !model.accessibilityOK || !connected {
                showMainWindow()
                model.section = .settings
            }
        }
    }

    func stop() {
        interaction.cancel(restoreFocus: false)
        startupTask?.cancel()
        statusTask?.cancel()
        connectionRevision = UUID()
        connectionTask?.cancel()
        keyTask?.cancel()
        for task in catalogTasks.values { task.cancel() }
    }

    func showMainWindow() {
        allowsStartupWindow = false
        refreshPermissions()
        refreshConnectionStatus()
        mainWindow.show()
    }

    private func openPopup() {
        if overlay.isVisible, overlay.model.phase == .picking || overlay.model.phase == .input {
            cancelActive()
            return
        }
        begin(.picker)
    }

    private func triggerMode(id: UUID) {
        guard let mode = mainWindow.model.settings.mode(withID: id) else { return }
        begin(.mode(mode))
    }

    private func begin(_ entry: Entry, retryInput: String? = nil) {
        allowsStartupWindow = false
        // Capture identity before dismissing the old panel or presenting Sable.
        let source = NativeInteractionDelivery.captureSource()
        interaction.cancel(restoreFocus: false, finalText: overlay.model.reviewSession?.state.text)
        overlay.close()
        self.entry = entry
        self.retryInput = retryInput
        usesPill = false
        activeMode = nil
        selectedText = ""
        runProvider = nil
        guard ensureAccessibility() else {
            showMainWindow(); mainWindow.model.section = .settings
            return
        }
        interaction.begin(source: source)
    }

    private func handle(_ event: InteractionEvent) {
        switch event {
        case let .captured(id, text, _):
            selectedText = text
            let current = mainWindow.model.settings
            switch entry {
            case .picker:
                overlay.presentPicker(selectedText: text, modes: current.modes,
                                      initialModeID: current.defaultMode?.id, interactionID: id)
            case let .mode(mode):
                activeMode = mode
                usesPill = !mode.requiresInput && current.resultHandling(for: mode) == .quickCopy
                if !mode.requiresInput && text.isEmpty {
                    overlay.showNotice(.message(title: "No text selected", detail: "Select text, then try again."), interactionID: id)
                    return
                }
                if !usesPill {
                    overlay.present(mode: mode, selectedText: text, modes: current.modes, interactionID: id)
                }
                if let retryInput { runActive(input: retryInput); self.retryInput = nil }
                else if !mode.requiresInput { runActive(input: "") }
            }
        case let .running(id):
            if usesPill { overlay.showNotice(.running(modeName: activeMode?.name ?? "Rewrite"), interactionID: id) }
            else { overlay.showRunning(interactionID: id) }
            updateStatus("Rewriting")
        case let .review(id, text, source):
            overlay.showReview(result: text, target: ReviewTarget(sourceAppName: source.name, canPasteBack: source.canPasteBack), interactionID: id)
            updateStatus("Review")
        case let .copied(id, notice):
            if let notice { overlay.showNotice(.message(title: notice == "Pasted" ? "Pasted" : "Copied only", detail: notice == "Pasted" ? nil : notice), interactionID: id) }
            else { overlay.showNotice(.copied, interactionID: id) }
            updateStatus(notice ?? "Copied")
        case let .failed(id, error):
            if runProvider == .chatGPT { refreshConnectionStatus() }
            guard let failure = OverlayFailure.classify(error, provider: runProvider) else { return }
            if usesPill || overlay.currentInteractionID != id { overlay.showNotice(.failure(failure), interactionID: id) }
            else { overlay.showFailure(failure, interactionID: id) }
            updateStatus("Failed")
        }
    }

    private func switchMode(to id: UUID) {
        guard overlay.model.phase == .picking || overlay.model.phase == .input,
              let mode = mainWindow.model.settings.mode(withID: id) else { return }
        activeMode = mode
        overlay.model.configure(mode: mode, selectedText: selectedText, modes: mainWindow.model.settings.modes)
        if !mode.requiresInput { runActive(input: "") }
    }

    private func runActive(input: String) {
        guard let id = interaction.interactionID, let mode = activeMode else { return }
        guard mode.requiresInput || !selectedText.isEmpty else {
            overlay.showNotice(.message(title: "No text selected", detail: "Select text, then try again."), interactionID: id)
            return
        }
        lastInput = input
        runProvider = mainWindow.model.settings.generationSelection(for: mode).provider
        interaction.run(id: id, mode: mode, settings: mainWindow.model.settings, input: input)
    }

    private func cancelActive() {
        interaction.cancel(finalText: overlay.model.reviewSession?.state.text)
        activeMode = nil
        updateStatus("Idle")
    }

    private func handleFailureAction(_ action: OverlayFailure.Action, id: UUID) {
        guard interaction.interactionID == id else { return }
        switch action {
        case .retry:
            if let activeMode { begin(.mode(activeMode), retryInput: lastInput) }
        case .openSettings:
            interaction.cancel(restoreFocus: false)
            showMainWindow()
            mainWindow.model.section = .settings
        case .manageUsage:
            interaction.cancel(restoreFocus: false)
            if let url = URL(string: "https://chatgpt.com/settings/usage") { NSWorkspace.shared.open(url) }
        case .close:
            cancelActive()
        }
    }

    // MARK: Connection actions

    /// Token refresh can invalidate a connection during generation. Re-read its
    /// public status when a failure or Settings opening exposes that change;
    /// this never initiates sign-in or loads a secret into the view model.
    private func refreshConnectionStatus() {
        statusTask?.cancel()
        let revision = connectionRevision
        statusTask = Task { [weak self] in
            guard let self else { return }
            let status = await connection.status()
            guard connectionRevision == revision, !Task.isCancelled else { return }
            let previous = mainWindow.model.connectionStatus
            mainWindow.model.connectionStatus = status
            if previous.activeAccount?.id != status.activeAccount?.id || previous.planUsageEnabled != status.planUsageEnabled {
                invalidateCatalog(.chatGPT)
                await catalog.invalidate()
            }
        }
    }

    private func connectChatGPT() {
        let predecessor = connectionTask
        predecessor?.cancel()
        let revision = UUID()
        connectionRevision = revision
        let choice = providerChoiceRevision
        mainWindow.model.connectionActivity = .signingIn
        mainWindow.model.connectionIssue = nil
        connectionTask = Task { [weak self] in
            // Drain the previous lifecycle operation before beginning another.
            // A late cancel/disconnect must never reach a newer sign-in.
            await predecessor?.value
            guard let self, connectionRevision == revision, !Task.isCancelled else { return }
            do {
                try await connection.signIn { url in
                    guard NSWorkspace.shared.open(url) else { throw ConnectionError.browserOpenFailed }
                }
                guard connectionRevision == revision, !Task.isCancelled else { return }
                let status = await connection.status()
                guard connectionRevision == revision, !Task.isCancelled else { return }
                mainWindow.model.connectionStatus = status
                if status.planUsageEnabled, !status.needsReconnect {
                    if providerChoiceRevision == choice {
                        var updated = mainWindow.model.settings
                        updated.generation = GenerationSelection(provider: .chatGPT)
                        mainWindow.model.applyLoadedSettings(updated)
                        saveSettings(updated)
                    }
                    if !UserDefaults.standard.bool(forKey: "sable.didShowChatGPTWelcome") {
                        mainWindow.model.showsChatGPTWelcome = true
                        UserDefaults.standard.set(true, forKey: "sable.didShowChatGPTWelcome")
                    }
                }
                mainWindow.model.connectionActivity = .idle
                refreshModels(.chatGPT)
            } catch {
                guard connectionRevision == revision, !Task.isCancelled else { return }
                let status = await connection.status()
                guard connectionRevision == revision, !Task.isCancelled else { return }
                mainWindow.model.connectionStatus = status
                mainWindow.model.connectionActivity = .idle
                if !(error is CancellationError) {
                    mainWindow.model.connectionIssue = .signInFailed(Self.connectionMessage(error))
                }
            }
        }
    }

    private func cancelChatGPTSignIn() {
        let predecessor = connectionTask
        predecessor?.cancel()
        let revision = UUID()
        connectionRevision = revision
        connectionTask = Task { [weak self] in
            await predecessor?.value
            guard let self, connectionRevision == revision, !Task.isCancelled else { return }
            await connection.cancelSignIn()
            guard connectionRevision == revision, !Task.isCancelled else { return }
            let status = await connection.status()
            guard connectionRevision == revision, !Task.isCancelled else { return }
            mainWindow.model.connectionStatus = status
            mainWindow.model.connectionActivity = .idle
        }
    }

    private func disconnectChatGPT() {
        let predecessor = connectionTask
        predecessor?.cancel()
        let revision = UUID()
        connectionRevision = revision
        invalidateCatalog(.chatGPT)
        mainWindow.model.connectionActivity = .disconnecting
        mainWindow.model.connectionIssue = nil
        connectionTask = Task { [weak self] in
            await predecessor?.value
            guard let self, connectionRevision == revision, !Task.isCancelled else { return }
            var issue: ConnectionIssue?
            do { try await connection.disconnect() }
            catch ConnectionError.remoteRevocationUnconfirmed { issue = .remoteSignOutUnconfirmed }
            catch { issue = .disconnectFailed(Self.connectionMessage(error)) }
            guard connectionRevision == revision, !Task.isCancelled else { return }
            let status = await connection.status()
            guard connectionRevision == revision, !Task.isCancelled else { return }
            mainWindow.model.connectionStatus = status
            mainWindow.model.connectionActivity = .idle
            mainWindow.model.connectionIssue = issue
            await catalog.invalidate()
        }
    }

    private func saveOpenRouterKey(_ secret: ConnectionSecret?) {
        let predecessor = keyTask
        let revision = UUID()
        keyRevision = revision
        invalidateCatalog(.openRouter)
        mainWindow.model.openRouterKeyIssue = nil
        // Serialize writes instead of canceling an actor write after it began.
        // The latest action always wins on disk, and only it publishes UI state.
        keyTask = Task { [weak self] in
            await predecessor?.value
            guard let self, keyRevision == revision, !Task.isCancelled else { return }
            do {
                if let secret { try await keyStore.saveKey(secret) }
                else { try await keyStore.removeKey() }
                guard keyRevision == revision, !Task.isCancelled else { return }
                let hasKey = try await keyStore.hasKey()
                guard keyRevision == revision, !Task.isCancelled else { return }
                mainWindow.model.hasOpenRouterKey = hasKey
                await catalog.invalidate()
            } catch {
                guard keyRevision == revision, !Task.isCancelled else { return }
                mainWindow.model.openRouterKeyIssue = "Could not update the protected OpenRouter key. Check ~/.config/sable permissions and try again."
            }
        }
    }

    private func invalidateCatalog(_ provider: GenerationProvider) {
        catalogTasks[provider]?.cancel()
        catalogRevisions[provider] = UUID()
        mainWindow.model.modelCatalogs[provider] = .idle
    }

    private func refreshModels(_ provider: GenerationProvider) {
        guard provider != .legacyCLI else { return }
        invalidateCatalog(provider)
        let revision = UUID()
        catalogRevisions[provider] = revision
        mainWindow.model.modelCatalogs[provider] = .loading
        catalogTasks[provider] = Task { [weak self] in
            guard let self else { return }
            await catalog.invalidate()
            guard catalogRevisions[provider] == revision, !Task.isCancelled else { return }
            do {
                let models = try await catalog.models(for: provider)
                guard catalogRevisions[provider] == revision, !Task.isCancelled else { return }
                mainWindow.model.modelCatalogs[provider] = .loaded(models)
            } catch {
                guard catalogRevisions[provider] == revision, !Task.isCancelled else { return }
                mainWindow.model.modelCatalogs[provider] = .failed(error.localizedDescription)
            }
        }
    }

    private static func connectionMessage(_ error: Error) -> String {
        (error as? ConnectionError)?.localizedDescription ?? "ChatGPT connection failed. Try again from Settings."
    }

    // MARK: Persistence and permissions

    private func persistAndDisplay(_ record: RunRecord) {
        records = (try? historyStore.upsert(record)) ?? RunHistoryStore.upserting(record, into: records, maxRecords: 50)
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
        if ClipboardWriter().write(output) != nil { updateStatus("Copied") }
        else { updateStatus("Could not write the clipboard. The output is still in History.") }
    }

    private func saveSettings(_ newSettings: SableSettings) {
        let codexChanged = newSettings.runtimePaths.codexPath != settings.runtimePaths.codexPath
        settings = newSettings
        try? settingsStore.save(newSettings)
        hotkeys.syncModeHotkeys(newSettings.modes)
        if codexChanged, newSettings.generation.provider == .legacyCLI { detectCodexModels() }
    }

    private func detectCodexModels() {
        let command = settings.runtimePaths.command(for: .codex)
        Task { [weak self] in
            let models = await CodexModelCatalog.detect(command: command)
            guard let self, settings.runtimePaths.command(for: .codex) == command else { return }
            mainWindow.model.detectedCodexModels = models
        }
    }

    private func refreshPermissions() {
        mainWindow.model.accessibilityOK = AXIsProcessTrusted()
        mainWindow.model.screenRecordingOK = CGPreflightScreenCaptureAccess()
    }

    private func openSystemSettings(_ kind: PermissionKind) {
        let raw = kind == .accessibility
            ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
    }

    private func updateStatus(_ status: String) { mainWindow.model.currentRun = status }

    private func ensureAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
