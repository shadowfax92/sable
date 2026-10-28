import Foundation

/// App-owned storage locations, separate from CLI authentication and settings.
/// The connection piece must create private directories (0700) and write secrets
/// atomically with mode 0600 before exposure, including replacement/temp files.
public struct ConnectionStorageLocations: Equatable, Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func standard(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ConnectionStorageLocations {
        ConnectionStorageLocations(directory: homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("sable", isDirectory: true))
    }

    public var chatGPTCredentials: URL { directory.appendingPathComponent("chatgpt-credentials.json") }
    public var hostIdentity: URL { directory.appendingPathComponent("host-identity.json") }
    public var openRouterKey: URL { directory.appendingPathComponent("openrouter-key") }
}

/// A protected OpenRouter key store, consumed by settings and generation only.
/// hasKey exposes no secret; loadKey is for the transport. Implementations use
/// ConnectionStorageLocations and atomic 0600 writes, never settings JSON or logs.
public protocol OpenRouterKeyStore: Sendable {
    func hasKey() async throws -> Bool
    func loadKey() async throws -> ConnectionSecret?
    func saveKey(_ key: ConnectionSecret) async throws
    func removeKey() async throws
}

/// Placeholder for the direct-generation piece's protected key configuration.
/// Every operation fails explicitly instead of pretending a key was saved/removed.
public struct UnimplementedOpenRouterKeyStore: OpenRouterKeyStore {
    public init() {}

    public func hasKey() async throws -> Bool { throw ConnectionError.notImplemented }
    public func loadKey() async throws -> ConnectionSecret? { throw ConnectionError.notImplemented }
    public func saveKey(_ key: ConnectionSecret) async throws { throw ConnectionError.notImplemented }
    public func removeKey() async throws { throw ConnectionError.notImplemented }
}
