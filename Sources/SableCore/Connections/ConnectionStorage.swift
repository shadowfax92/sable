import Foundation
import Darwin

/// App-owned storage locations, separate from CLI authentication and settings.
/// The shared protected writer creates private directories (0700) and writes
/// secrets atomically with mode 0600, including replacement/temporary files.
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

/// Explicit unavailable key configuration; production uses FileOpenRouterKeyStore.
/// Every operation fails explicitly instead of pretending a key was saved/removed.
public struct UnimplementedOpenRouterKeyStore: OpenRouterKeyStore {
    public init() {}

    public func hasKey() async throws -> Bool { throw ConnectionError.notImplemented }
    public func loadKey() async throws -> ConnectionSecret? { throw ConnectionError.notImplemented }
    public func saveKey(_ key: ConnectionSecret) async throws { throw ConnectionError.notImplemented }
    public func removeKey() async throws { throw ConnectionError.notImplemented }
}

/// File-backed key configuration shared by settings and the generation transport.
/// Only `hasKey` belongs in UI state; the existing key is never returned to a view.
public actor FileOpenRouterKeyStore: OpenRouterKeyStore {
    private let files: ProtectedConnectionFiles

    public init(locations: ConnectionStorageLocations = .standard()) {
        files = ProtectedConnectionFiles(locations: locations)
    }

    public func hasKey() throws -> Bool { try loadKey() != nil }

    public func loadKey() throws -> ConnectionSecret? {
        guard let data = try files.read(files.locations.openRouterKey) else { return nil }
        guard let key = String(data: data, encoding: .utf8), Self.isValid(key) else {
            throw ConnectionError.invalidKey
        }
        return ConnectionSecret(key)
    }

    public func saveKey(_ key: ConnectionSecret) throws {
        guard Self.isValid(key.rawValue) else { throw ConnectionError.invalidKey }
        try files.write(Data(key.rawValue.utf8), to: files.locations.openRouterKey)
    }

    public func removeKey() throws { try files.remove(files.locations.openRouterKey) }

    private static func isValid(_ key: String) -> Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && key.utf8.count <= 16_384
            && !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

/// The single persistence boundary for OAuth and API keys. Temporary files are
/// private *before* receiving bytes; rename commits a whole token set at once.
/// O_NOFOLLOW and ownership checks prevent following substituted secret files.
struct ProtectedConnectionFiles: Sendable {
    let locations: ConnectionStorageLocations
    private let maximumSize = 1_048_576

    func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: locations.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw ConnectionError.storageUnavailable }
        var info = stat()
        guard lstat(locations.directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), chmod(locations.directory.path, 0o700) == 0 else {
            throw ConnectionError.storageUnavailable
        }
    }

    func read(_ url: URL) throws -> Data? {
        // A brand-new connection must not create owner configuration just to
        // answer status. Mutation/authorization explicitly prepares the directory.
        var directoryInfo = stat()
        if lstat(locations.directory.path, &directoryInfo) != 0 {
            guard errno == ENOENT else { throw ConnectionError.storageUnavailable }
            return nil
        }
        try prepareDirectory()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ConnectionError.storageUnavailable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size <= maximumSize, fchmod(fd, 0o600) == 0 else {
            throw ConnectionError.storageUnavailable
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == -1 && errno == EINTR { continue }
            guard count >= 0 else { throw ConnectionError.storageUnavailable }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximumSize else { throw ConnectionError.storageUnavailable }
        }
        return result
    }

    func write(_ data: Data, to url: URL) throws {
        try prepareDirectory()
        guard data.count <= maximumSize else { throw ConnectionError.storageUnavailable }
        let temporary = locations.directory.appendingPathComponent(".connection-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ConnectionError.storageUnavailable }
        defer { close(fd); unlink(temporary.path) }
        guard fchmod(fd, 0o600) == 0 else { throw ConnectionError.storageUnavailable }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count == -1 && errno == EINTR { continue }
                guard count > 0 else { throw ConnectionError.storageUnavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw ConnectionError.storageUnavailable
        }
        // Persist the rename as well as the contents. A crash must not resurrect
        // the previous refresh token after the provider has rotated it.
        let directoryFD = open(locations.directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ConnectionError.storageUnavailable }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw ConnectionError.storageUnavailable }
    }

    func remove(_ url: URL) throws {
        if unlink(url.path) != 0 && errno != ENOENT { throw ConnectionError.storageUnavailable }
    }

    /// Hold this lease across refresh HTTP, not just file writes. Separate app
    /// instances must reread the latest grant under the same lease before rotating.
    func lock() async throws -> ConnectionFileLease {
        try prepareDirectory()
        let path = locations.directory.appendingPathComponent(".chatgpt.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw ConnectionError.storageUnavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              fchmod(fd, 0o600) == 0 else {
            close(fd)
            throw ConnectionError.storageUnavailable
        }
        do {
            // Nonblocking acquisition keeps the actor and caller cancellation
            // responsive while another process owns the renewable session.
            for _ in 0..<1_200 {
                try Task.checkCancellation()
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { return ConnectionFileLease(fd: fd) }
                guard errno == EWOULDBLOCK || errno == EINTR else { throw ConnectionError.storageUnavailable }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw ConnectionError.storageUnavailable
        } catch { close(fd); throw error }
    }
}

/// Sole owner of a process-wide file lock. Releasing on deinit also covers every
/// throwing/cancelled path across a suspended HTTP refresh.
final class ConnectionFileLease: @unchecked Sendable {
    private let fd: Int32
    init(fd: Int32) { self.fd = fd }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
