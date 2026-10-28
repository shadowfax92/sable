import Foundation

/// CLI-only context stays at the adapter boundary. Direct generation neither
/// starts a harness nor consumes filesystem screenshots or CLI model names.
public struct CLIGenerationContext: Equatable, Sendable {
    public var runtimeID: RuntimeID
    public var runtimeSettings: RuntimeSettings
    public var cwd: URL
    public var model: String
    public var screenshotPath: String?

    public init(
        runtimeID: RuntimeID,
        runtimeSettings: RuntimeSettings = RuntimeSettings(),
        cwd: URL,
        model: String = "default",
        screenshotPath: String? = nil
    ) {
        self.runtimeID = runtimeID
        self.runtimeSettings = runtimeSettings
        self.cwd = cwd
        self.model = model
        self.screenshotPath = screenshotPath
    }
}

/// One immutable rewrite input. The interaction owner snapshots settings before
/// starting a task and owns cancellation and delivery of the completed string.
public struct GenerationRequest: Equatable, Sendable {
    public var selection: GenerationSelection
    public var instruction: String
    public var selectedText: String
    public var timeoutSeconds: TimeInterval
    public var cli: CLIGenerationContext?

    public init(
        selection: GenerationSelection,
        instruction: String,
        selectedText: String,
        timeoutSeconds: TimeInterval = 120,
        cli: CLIGenerationContext? = nil
    ) {
        self.selection = selection
        self.instruction = instruction
        self.selectedText = selectedText
        self.timeoutSeconds = timeoutSeconds
        self.cli = cli
    }
}

/// The app's single text-generation seam. Implementations propagate task
/// cancellation and return only complete output, never a partially received stream.
public protocol TextGenerating: Sendable {
    func rewrite(_ request: GenerationRequest) async throws -> String
}

/// A provider-owned model identity and its user-facing label. Catalog ordering
/// must be preserved; ChatGPT entries come from the active account, not Codex CLI.
public struct GenerationModel: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Discovery stays behind the generation module. Account changes invalidate
/// cached choices; discovery failure cannot trigger a provider switch.
public protocol GenerationModelCatalog: Sendable {
    func models(for provider: GenerationProvider) async throws -> [GenerationModel]
}

/// Stable failures at the generation boundary. Provider diagnostics contain only
/// safe classification metadata, never response bodies or authorization values.
public enum GenerationError: Error, Equatable, Sendable {
    case notImplemented(GenerationProvider)
    case missingCLIContext
    case missingOpenRouterKey
    case noModels
    case modelUnavailable
    case accountChanged
    case invalidResponse
    case interrupted
    case incomplete
    case refused
    case emptyOutput
    case deadlineExceeded
    case networkUnavailable
    case responseTooLarge
    case providerFailure(GenerationFailure)
}

/// Routes exactly once to the selected adapter. Errors propagate to the caller;
/// this module never falls through to another provider or consumes fallback credit.
public struct GenerationService: TextGenerating {
    private let chatGPT: any TextGenerating
    private let openRouter: any TextGenerating
    private let cli: any TextGenerating

    public init(
        chatGPT: any TextGenerating = ChatGPTGenerationAdapter(),
        openRouter: any TextGenerating = OpenRouterGenerationAdapter(),
        cli: any TextGenerating = CLIGenerationAdapter()
    ) {
        self.chatGPT = chatGPT
        self.openRouter = openRouter
        self.cli = cli
    }

    public func rewrite(_ request: GenerationRequest) async throws -> String {
        try Task.checkCancellation()
        let output: String
        switch request.selection.provider {
        case .chatGPT: output = try await chatGPT.rewrite(request)
        case .openRouter: output = try await openRouter.rewrite(request)
        case .legacyCLI: output = try await cli.rewrite(request)
        }
        try Task.checkCancellation()
        return output
    }
}
