import Foundation

/// Account-aware discovery shared by settings and adapters. This actor caches
/// only public model metadata, never credentials. Switching registrations clears
/// the ChatGPT cache; a bounded TTL also picks up server-side entitlement changes.
public actor DirectGenerationModelCatalog: GenerationModelCatalog {
    public static let defaultOpenRouterModel = "openai/gpt-4.1-mini"
    private let connection: any ChatGPTConnecting
    private let keyStore: any OpenRouterKeyStore
    private let httpClient: any GenerationHTTPClient
    private let cacheLifetime: TimeInterval
    private let timeoutSeconds: TimeInterval
    private var accountID: String?
    private var chatGPTCache: (models: [GenerationModel], date: Date)?
    private var openRouterCache: (models: [GenerationModel], date: Date)?
    private var nonReasoningModels: Set<String> = []

    public init(
        connection: any ChatGPTConnecting = UnimplementedChatGPTConnection(),
        keyStore: any OpenRouterKeyStore = UnimplementedOpenRouterKeyStore(),
        httpClient: any GenerationHTTPClient = URLSessionGenerationHTTPClient.shared,
        cacheLifetime: TimeInterval = 300,
        timeoutSeconds: TimeInterval = 20
    ) {
        self.connection = connection
        self.keyStore = keyStore
        self.httpClient = httpClient
        self.cacheLifetime = cacheLifetime
        self.timeoutSeconds = timeoutSeconds
    }

    public func models(for provider: GenerationProvider) async throws -> [GenerationModel] {
        try await withGenerationDeadline(seconds: timeoutSeconds) { try await self.load(provider) }
    }

    /// A manual refresh is useful after permissions change without an account
    /// switch. The normal rewrite path reuses the five-minute metadata cache.
    public func invalidate() {
        accountID = nil
        chatGPTCache = nil
        openRouterCache = nil
        nonReasoningModels = []
    }

    func canDisableReasoning(model: String) -> Bool { nonReasoningModels.contains(model) }

    private func load(_ provider: GenerationProvider) async throws -> [GenerationModel] {
        try Task.checkCancellation()
        switch provider {
        case .legacyCLI: return []
        case .chatGPT:
            let token = try await connection.accessToken()
            if accountID != token.accountID {
                accountID = token.accountID
                chatGPTCache = nil
            }
            if let cache = chatGPTCache, Date().timeIntervalSince(cache.date) < cacheLifetime { return cache.models }
            let request = try generationHTTPRequest(url: "https://api.openai.com/v1/models", secret: token.secret)
            let payload = try await generationJSON(client: httpClient, request: request, provider: provider)
            guard let entries = payload["models"] as? [[String: Any]] else { throw GenerationError.invalidResponse }
            var models: [GenerationModel] = []
            for entry in entries where entry["visibility"] as? String == "list" {
                guard let slug = entry["slug"] as? String, !slug.isEmpty,
                      let name = entry["display_name"] as? String, !name.isEmpty else { throw GenerationError.invalidResponse }
                models.append(GenerationModel(id: slug, displayName: name))
            }
            // Discovery may overlap sign-out/replacement. Never publish a stale
            // account's catalog, or allow its completion to populate the new cache.
            let current = try await connection.accessToken()
            guard current.accountID == token.accountID, accountID == token.accountID else { throw GenerationError.accountChanged }
            guard !models.isEmpty else { throw GenerationError.noModels }
            chatGPTCache = (models, Date())
            return models
        case .openRouter:
            guard let key = try await keyStore.loadKey(), !key.rawValue.isEmpty else { throw GenerationError.missingOpenRouterKey }
            if let cache = openRouterCache, Date().timeIntervalSince(cache.date) < cacheLifetime { return cache.models }
            let request = try generationHTTPRequest(url: "https://openrouter.ai/api/v1/models", secret: key)
            let payload = try await generationJSON(client: httpClient, request: request, provider: provider)
            guard let entries = payload["data"] as? [[String: Any]] else { throw GenerationError.invalidResponse }
            var models: [GenerationModel] = []
            var canDisable: Set<String> = []
            for entry in entries {
                guard let id = entry["id"] as? String, !id.isEmpty,
                      let name = entry["name"] as? String, !name.isEmpty else { throw GenerationError.invalidResponse }
                let architecture = entry["architecture"] as? [String: Any]
                // The public catalog also contains image/audio-only models.
                guard let input = architecture?["input_modalities"] as? [String], input.contains("text"),
                      let output = architecture?["output_modalities"] as? [String], output.contains("text") else { continue }
                models.append(GenerationModel(id: id, displayName: name))
                let parameters = entry["supported_parameters"] as? [String] ?? []
                let reasoning = entry["reasoning"] as? [String: Any]
                // Explicit null means every gateway effort is supported;
                // an absent field means effort selection is not exposed.
                let efforts = reasoning?["supported_efforts"]
                let supportsNone = (efforts as? [String])?.contains("none") == true || efforts is NSNull
                if parameters.contains("reasoning"),
                   reasoning?["mandatory"] as? Bool == false, supportsNone {
                    canDisable.insert(id)
                }
            }
            guard !models.isEmpty else { throw GenerationError.noModels }
            nonReasoningModels = canDisable
            openRouterCache = (models, Date())
            return models
        }
    }
}
