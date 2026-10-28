import Foundation

/// Generation routing is separate from RuntimeID, which identifies only CLI
/// process harnesses. Direct providers must never be represented as a process.
public enum GenerationProvider: String, Codable, Equatable, Sendable {
    case legacyCLI
    case chatGPT
    case openRouter
}

/// A persisted explicit provider choice. A nil direct model asks that provider
/// to resolve its own catalog default; it never authorizes a provider fallback.
public struct GenerationSelection: Codable, Equatable, Sendable {
    public var provider: GenerationProvider
    /// Ignored for legacyCLI, which keeps using SableMode.model.
    public var model: String?

    public init(provider: GenerationProvider, model: String? = nil) {
        self.provider = provider
        self.model = model
    }
}
