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

/// Calls the public Responses API with a freshly acquired Sable-owned token.
/// The catalog and connection should be the same instances used by Settings;
/// direct requests contain only text and never invoke a CLI, tools or screenshots.
public struct ChatGPTGenerationAdapter: TextGenerating {
    private let connection: any ChatGPTConnecting
    private let catalog: any GenerationModelCatalog
    private let httpClient: any GenerationHTTPClient

    public init(
        connection: any ChatGPTConnecting = UnimplementedChatGPTConnection(),
        catalog: (any GenerationModelCatalog)? = nil,
        httpClient: any GenerationHTTPClient = URLSessionGenerationHTTPClient.shared
    ) {
        self.connection = connection
        self.catalog = catalog ?? DirectGenerationModelCatalog(connection: connection, httpClient: httpClient)
        self.httpClient = httpClient
    }

    public func rewrite(_ request: GenerationRequest) async throws -> String {
        try await withGenerationDeadline(seconds: request.timeoutSeconds) {
            do {
                let token = try await connection.accessToken()
                let models = try await catalog.models(for: .chatGPT)
                let model = request.selection.model ?? models.first?.id
                guard let model, models.contains(where: { $0.id == model }) else { throw GenerationError.modelUnavailable }
                let current = try await connection.accessToken()
                guard current.accountID == token.accountID else { throw GenerationError.accountChanged }
                let httpRequest = try generationHTTPRequest(
                    url: "https://api.openai.com/v1/responses", secret: current.secret,
                    body: ["model": model, "store": false, "stream": true,
                           "instructions": directGenerationInstruction(request),
                           "input": [["role": "user", "content": request.selectedText]]]
                )
                let text = try await generationTextStream(client: httpClient, request: httpRequest, provider: .chatGPT)
                let final = try await connection.accessToken()
                guard final.accountID == token.accountID else { throw GenerationError.accountChanged }
                return text
            } catch { throw generationNetworkError(error) }
        }
    }
}

/// OpenRouter is an explicit paid selection. The app injects its protected key
/// store; this adapter never writes a key or changes provider/model after failure.
public struct OpenRouterGenerationAdapter: TextGenerating {
    private let keyStore: any OpenRouterKeyStore
    private let catalog: any GenerationModelCatalog
    private let httpClient: any GenerationHTTPClient

    public init(
        keyStore: any OpenRouterKeyStore = UnimplementedOpenRouterKeyStore(),
        catalog: (any GenerationModelCatalog)? = nil,
        httpClient: any GenerationHTTPClient = URLSessionGenerationHTTPClient.shared
    ) {
        self.keyStore = keyStore
        self.catalog = catalog ?? DirectGenerationModelCatalog(keyStore: keyStore, httpClient: httpClient)
        self.httpClient = httpClient
    }

    public func rewrite(_ request: GenerationRequest) async throws -> String {
        try await withGenerationDeadline(seconds: request.timeoutSeconds) {
            do {
                guard let key = try await keyStore.loadKey(), !key.rawValue.isEmpty else { throw GenerationError.missingOpenRouterKey }
                let models = try await catalog.models(for: .openRouter)
                let model = request.selection.model ?? DirectGenerationModelCatalog.defaultOpenRouterModel
                guard models.contains(where: { $0.id == model }) else { throw GenerationError.modelUnavailable }
                var body: [String: Any] = [
                    "model": model, "stream": true,
                    "provider": ["sort": "latency", "allow_fallbacks": false],
                    "messages": [["role": "system", "content": directGenerationInstruction(request)],
                                 ["role": "user", "content": request.selectedText]]
                ]
                // The default compact model has no reasoning knob. Optional
                // reasoning is disabled only when catalog capabilities say none
                // is supported; never invent a per-model parameter or effort.
                if let direct = catalog as? DirectGenerationModelCatalog,
                   await direct.canDisableReasoning(model: model) {
                    body["reasoning"] = ["effort": "none"]
                }
                let httpRequest = try generationHTTPRequest(
                    url: "https://openrouter.ai/api/v1/chat/completions", secret: key, body: body
                )
                return try await generationTextStream(client: httpClient, request: httpRequest, provider: .openRouter)
            } catch { throw generationNetworkError(error) }
        }
    }
}

/// Keep caller-authored instructions verbatim and put selected text in its own
/// user message. CLI prompt formatting (paths, screenshot tags) is not reused.
private func directGenerationInstruction(_ request: GenerationRequest) -> String {
    request.instruction.isEmpty ? "Rewrite the selected text. Return only the rewritten text." : request.instruction
}
