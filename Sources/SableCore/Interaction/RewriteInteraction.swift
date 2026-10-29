import Foundation

/// Captured before the panel appears. Native closures retain the exact running
/// application object, so a recycled PID can never become a paste destination.
@MainActor
public struct InteractionSource {
    public let processIdentifier: Int32?
    public let name: String?
    public let canPasteBack: Bool
    public var isFrontmost: () -> Bool
    public var activate: () -> Bool
    public var isReadyForPaste: () -> Bool
    public var paste: () -> Bool

    public init(processIdentifier: Int32? = nil, name: String? = nil, canPasteBack: Bool = false,
                isFrontmost: @escaping () -> Bool = { false },
                activate: @escaping () -> Bool = { false },
                isReadyForPaste: @escaping () -> Bool = { false },
                paste: @escaping () -> Bool = { false }) {
        self.processIdentifier = processIdentifier
        self.name = name
        self.canPasteBack = canPasteBack
        self.isFrontmost = isFrontmost
        self.activate = activate
        self.isReadyForPaste = isReadyForPaste
        self.paste = paste
    }
}

/// A CLI-only temporary attachment. Its owner deletes it once, including when a
/// run is superseded. Direct requests never create an attachment.
@MainActor
public struct InteractionAttachment {
    public let path: String
    public let cleanup: () -> Void

    public init(path: String, cleanup: @escaping () -> Void) {
        self.path = path
        self.cleanup = cleanup
    }
}

public enum InteractionAction { case copy, paste, discard }

public enum InteractionDeliveryError: Error, LocalizedError {
    case clipboardUnavailable
    public var errorDescription: String? {
        "Could not write the clipboard. Your final edit is saved in History; copy it again when the clipboard is available."
    }
}

/// Events cross into the UI only while their interaction is current. Completed
/// generation is a review state, not a successful clipboard delivery.
@MainActor
public enum InteractionEvent {
    case captured(UUID, String, InteractionSource)
    case running(UUID)
    case review(UUID, String, InteractionSource)
    case copied(UUID, notice: String?)
    case failed(UUID, Error)
}

/// Owns one capture → generation → review → delivery lifecycle. All effects are
/// injected and run on the main actor; every suspension is followed by an ID and
/// cancellation check before state, history, clipboard or panel can change.
@MainActor
public final class RewriteInteraction {
    private final class Session {
        let id = UUID()
        let source: InteractionSource
        var text: String?
        var record: RunRecord?
        var attachment: InteractionAttachment?
        var phase: Phase = .capturing
        init(source: InteractionSource) { self.source = source }
    }
    private enum Phase { case capturing, ready, running, review, delivering, finished }

    public var onEvent: (InteractionEvent) -> Void = { _ in }
    public var onRecord: (RunRecord) -> Void = { _ in }
    public var onClose: (UUID) -> Void = { _ in }

    private let capture: (InteractionSource) async throws -> String
    private let screenshot: () throws -> InteractionAttachment
    private let generation: any TextGenerating
    private let writeClipboard: (String) -> Int?
    private let clipboardRevision: () -> Int
    private let pause: () async throws -> Void
    private let uptime: () -> TimeInterval
    private var session: Session?
    private var captureTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?

    public init(generation: any TextGenerating,
                capture: @escaping (InteractionSource) async throws -> String,
                screenshot: @escaping () throws -> InteractionAttachment,
                writeClipboard: @escaping (String) -> Int?,
                clipboardRevision: @escaping () -> Int,
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                focusPause: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 25_000_000) }) {
        self.generation = generation
        self.capture = capture
        self.screenshot = screenshot
        self.writeClipboard = writeClipboard
        self.clipboardRevision = clipboardRevision
        self.uptime = uptime
        self.pause = focusPause
    }

    public var interactionID: UUID? { session?.id }

    @discardableResult
    public func begin(source: InteractionSource) -> UUID {
        cancel(restoreFocus: false)
        let current = Session(source: source)
        session = current
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await capture(source)
                guard isCurrent(current) else { return }
                current.text = text
                current.phase = .ready
                onEvent(.captured(current.id, text, source))
            } catch {
                guard isCurrent(current) else { return }
                current.phase = .finished
                onEvent(.failed(current.id, error))
            }
        }
        return current.id
    }

    /// Settings and mode are value snapshots taken by the caller at submit time.
    /// Duplicate submits are ignored; one interaction starts one generation.
    public func run(id: UUID, mode: SableMode, settings: SableSettings, input: String) {
        guard let current = session, current.id == id, current.phase == .ready,
              let text = current.text else { return }
        current.phase = .running
        let instruction = Self.instruction(mode: mode, input: input)
        let selection = settings.generationSelection(for: mode)
        let handling = settings.resultHandling(for: mode)
        current.record = RunRecord(id: current.id, createdAt: Date(), completedAt: nil,
                                   status: .running, instruction: instruction.isEmpty ? mode.name : instruction,
                                   selectedText: text, screenshotPath: nil, outputText: nil, errorMessage: nil,
                                   modeName: mode.name, provider: selection.provider,
                                   model: selection.provider == .legacyCLI ? mode.model : selection.model)
        publishRecord(current)
        onEvent(.running(id))
        runTask = Task { [weak self] in
            guard let self, isCurrent(current) else { return }
            do {
                var cli: CLIGenerationContext?
                if selection.provider == .legacyCLI {
                    // Capture is deliberately deferred until the explicit CLI
                    // run, after the provider and screenshot preference resolve.
                    if settings.attachesScreenshotsForCLI {
                        current.attachment = try screenshot()
                    }
                    cli = CLIGenerationContext(runtimeID: mode.runtimeID, runtimeSettings: settings.runtimePaths,
                                               cwd: Self.expandHome(settings.cwd), model: mode.model,
                                               screenshotPath: current.attachment?.path)
                }
                let request = GenerationRequest(selection: selection, instruction: instruction,
                                                selectedText: text, timeoutSeconds: settings.timeoutSeconds, cli: cli)
                let output = try await generation.rewrite(request)
                guard isCurrent(current) else { return }
                current.record?.outputText = output
                current.record?.completedAt = Date()
                current.record?.status = .review
                cleanup(current)
                current.phase = .review
                publishRecord(current)
                if handling == .review {
                    onEvent(.review(id, output, current.source))
                } else {
                    accept(id: id, action: .copy, text: output, restoresSourceFocus: false)
                }
            } catch {
                guard isCurrent(current) else { return }
                current.phase = .finished
                current.record?.status = .failed
                current.record?.completedAt = Date()
                current.record?.errorMessage = error.localizedDescription
                cleanup(current)
                publishRecord(current)
                onEvent(.failed(id, error))
            }
        }
    }

    /// Only the review's final buffer is committed. Close is synchronous; paste
    /// waits at most ten 25ms focus polls and rechecks immediately before its key.
    public func deliver(id: UUID, action: InteractionAction, text: String) {
        accept(id: id, action: action, text: text, restoresSourceFocus: true)
    }

    private func accept(id: UUID, action: InteractionAction, text: String, restoresSourceFocus: Bool) {
        guard let current = session, current.id == id, current.phase == .review else { return }
        current.phase = .delivering
        current.record?.outputText = text
        current.record?.completedAt = Date()
        if action == .discard {
            current.record?.status = .discarded
            publishRecord(current)
            finish(current)
            _ = current.source.activate()
            return
        }
        guard let writtenRevision = writeClipboard(text) else {
            current.phase = .finished
            current.record?.status = .failed
            current.record?.errorMessage = InteractionDeliveryError.clipboardUnavailable.localizedDescription
            publishRecord(current)
            onEvent(.failed(id, InteractionDeliveryError.clipboardUnavailable))
            return
        }
        current.record?.status = .copied
        publishRecord(current)
        onClose(id)
        cleanup(current)
        let focusDeadline = uptime() + 0.25
        // Automatic quick-copy completion must not pull the user out of the app
        // they switched to while generation ran. Review acceptance is explicit.
        let activated = action == .paste || restoresSourceFocus ? current.source.activate() : false
        if action == .copy {
            current.phase = .finished
            onEvent(.copied(id, notice: nil))
            return
        }
        deliveryTask = Task { [weak self] in
            guard let self, isCurrent(current) else { return }
            if current.source.canPasteBack, activated {
                for attempt in 0...10 {
                    guard isCurrent(current) else { return }
                    guard uptime() <= focusDeadline, clipboardRevision() == writtenRevision else { break }
                    if current.source.isReadyForPaste() {
                        // There is no await between this guard and the native
                        // seam, which repeats live-target and permission checks.
                        guard isCurrent(current) else { return }
                        if current.source.paste() {
                            current.record?.status = .pasted
                            publishRecord(current)
                            current.phase = .finished
                            onEvent(.copied(id, notice: "Pasted"))
                            return
                        }
                        break
                    }
                    if attempt < 10 {
                        do { try await pause() } catch { return }
                        guard isCurrent(current) else { return }
                    }
                }
            }
            guard isCurrent(current) else { return }
            current.phase = .finished
            current.record?.errorMessage = clipboardRevision() == writtenRevision
                ? "Copied only. Focus the source app and press ⌘V; check Accessibility permission if paste-back remains unavailable."
                : "Clipboard changed before paste. Copy the result from History, then focus the source app and press ⌘V."
            publishRecord(current)
            onEvent(.copied(id, notice: current.record?.errorMessage))
        }
    }

    /// Invalidate before canceling tasks: a cancellation-insensitive adapter can
    /// finish later, but it can no longer publish or touch another session.
    public func cancel(restoreFocus: Bool = true, finalText: String? = nil) {
        guard let current = session else { return }
        session = nil
        captureTask?.cancel(); captureTask = nil
        runTask?.cancel(); runTask = nil
        deliveryTask?.cancel(); deliveryTask = nil
        if current.phase == .running || current.phase == .review {
            current.record?.status = current.phase == .review ? .discarded : .cancelled
            current.record?.completedAt = Date()
            if let finalText { current.record?.outputText = finalText }
            publishRecord(current)
        }
        cleanup(current)
        onClose(current.id)
        if restoreFocus { _ = current.source.activate() }
    }

    private func isCurrent(_ current: Session) -> Bool {
        session === current && !Task.isCancelled
    }

    private func finish(_ current: Session) {
        current.phase = .finished
        cleanup(current)
        onClose(current.id)
    }

    private func cleanup(_ current: Session) {
        let attachment = current.attachment
        current.attachment = nil
        attachment?.cleanup()
    }

    private func publishRecord(_ current: Session) {
        if let record = current.record { onRecord(record) }
    }

    private static func instruction(mode: SableMode, input: String) -> String {
        let base = mode.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return typed }
        return typed.isEmpty ? base : base + "\n\nAdditional instruction: " + typed
    }

    private static func expandHome(_ raw: String) -> URL {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path == "~" { return FileManager.default.homeDirectoryForCurrentUser }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}
