import Foundation

/// Public account metadata for settings. The stable id identifies a registration,
/// not an email: distinct registrations may share an email but own different grants.
public struct ConnectionAccount: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let email: String?

    public init(id: String, displayName: String, email: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.email = email
    }
}

/// A nonsecret snapshot. An in-flight replacement sign-in can coexist with the
/// previously verified account; cancelling that attempt must preserve the account.
public struct ConnectionStatus: Equatable, Sendable {
    public let activeAccount: ConnectionAccount?
    public let isSigningIn: Bool

    public init(activeAccount: ConnectionAccount? = nil, isSigningIn: Bool = false) {
        self.activeAccount = activeAccount
        self.isSigningIn = isSigningIn
    }
}

/// A credential passed only between connection storage and authenticated
/// transports. Descriptions are redacted; callers must never log rawValue.
/// Intentionally not Codable: settings and status cannot accidentally encode it.
public struct ConnectionSecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A refreshed bearer credential for one verified registration. Generation
/// acquires this per request instead of retaining tokens in app/UI settings.
public struct ConnectionAccessToken: Sendable {
    public let secret: ConnectionSecret
    public let expiresAt: Date
    public let accountID: String

    public init(secret: ConnectionSecret, expiresAt: Date, accountID: String) {
        self.secret = secret
        self.expiresAt = expiresAt
        self.accountID = accountID
    }
}

/// The UI owns opening a URL on the main actor. OAuth owns the callback listener
/// and all protocol validation; neither layer may log the authorization URL.
public typealias ConnectionBrowserOpener = @MainActor @Sendable (URL) async throws -> Void

/// Owns the ChatGPT connection lifecycle and protected credential persistence.
/// Implementations serialize token rotation, reject stale completions after
/// cancel/disconnect, and atomically commit only a fully verified sign-in.
public protocol ChatGPTConnecting: Sendable {
    func status() async -> ConnectionStatus
    /// Suspends until verified sign-in completes. Task cancellation and
    /// cancelSignIn both release the listener without replacing the active grant.
    @discardableResult
    func signIn(openBrowser: @escaping ConnectionBrowserOpener) async throws -> ConnectionAccount
    func cancelSignIn() async
    /// Cancels pending sign-in, stops token use and clears local tokens. Retain
    /// host identity and registration mapping; report unconfirmed remote revocation.
    func disconnect() async throws
    /// Refreshes near expiry and persists rotated tokens before returning. A
    /// disconnected, superseded or cancelled session must not supply a token.
    func accessToken() async throws -> ConnectionAccessToken
}

/// Nonsecret lifecycle failures. Implementations must translate transport errors
/// rather than attaching token responses, callback URLs or credential file bytes.
public enum ConnectionError: Error, Equatable, Sendable {
    case notImplemented
    case notConnected
    case signInInProgress
    case remoteRevocationUnconfirmed
}

/// Compiling placeholder only: does not open a browser, read credentials or
/// report a successful disconnect. The connection piece replaces this type.
public struct UnimplementedChatGPTConnection: ChatGPTConnecting {
    public init() {}

    public func status() async -> ConnectionStatus { ConnectionStatus() }

    public func signIn(openBrowser: @escaping ConnectionBrowserOpener) async throws -> ConnectionAccount {
        try Task.checkCancellation()
        throw ConnectionError.notImplemented
    }

    public func cancelSignIn() async {}

    public func disconnect() async throws { throw ConnectionError.notImplemented }

    public func accessToken() async throws -> ConnectionAccessToken {
        try Task.checkCancellation()
        throw ConnectionError.notImplemented
    }
}
