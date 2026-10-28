import Foundation

/// Preserves the existing CLI implementation behind the common rewrite seam.
/// ProcessClient remains injectable so headless tests never start a real agent.
public struct CLIGenerationAdapter: TextGenerating {
    private let processClient: any ProcessClient

    public init(processClient: any ProcessClient = FoundationProcessClient()) {
        self.processClient = processClient
    }

    public func rewrite(_ request: GenerationRequest) async throws -> String {
        try Task.checkCancellation()
        guard let context = request.cli else { throw GenerationError.missingCLIContext }
        return try await RuntimeRunner(processClient: processClient).run(RuntimeRunner.Request(
            runtimeID: context.runtimeID,
            runtimeSettings: context.runtimeSettings,
            cwd: context.cwd,
            timeoutSeconds: request.timeoutSeconds,
            prompt: PromptBuilder.build(
                instruction: request.instruction,
                selectedText: request.selectedText,
                screenshotPath: context.screenshotPath ?? ""
            ),
            model: context.model
        ))
    }
}

/// Deliberately unavailable until the direct-generation piece implements the
/// public Responses API, connection refresh, model discovery and terminal events.
public struct ChatGPTGenerationAdapter: TextGenerating {
    public init() {}

    public func rewrite(_ request: GenerationRequest) async throws -> String {
        try Task.checkCancellation()
        throw GenerationError.notImplemented(.chatGPT)
    }
}

/// Explicit paid-provider seam. The later implementation consumes the protected
/// OpenRouterKeyStore; selecting ChatGPT never implicitly invokes this adapter.
public struct OpenRouterGenerationAdapter: TextGenerating {
    public init() {}

    public func rewrite(_ request: GenerationRequest) async throws -> String {
        try Task.checkCancellation()
        throw GenerationError.notImplemented(.openRouter)
    }
}
