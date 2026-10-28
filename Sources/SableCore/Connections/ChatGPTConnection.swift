import Foundation
import CryptoKit

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
    public let planUsageEnabled: Bool
    public let needsReconnect: Bool

    public init(activeAccount: ConnectionAccount? = nil, isSigningIn: Bool = false,
                planUsageEnabled: Bool = false, needsReconnect: Bool = false) {
        self.activeAccount = activeAccount
        self.isSigningIn = isSigningIn
        self.planUsageEnabled = planUsageEnabled
        self.needsReconnect = needsReconnect
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
public enum ConnectionError: Error, Equatable, Sendable, LocalizedError {
    case notImplemented
    case notConnected
    case signInInProgress
    case remoteRevocationUnconfirmed
    case storageUnavailable
    case invalidKey
    case networkUnavailable
    case invalidDiscovery
    case listenerUnavailable
    case authorizationFailed
    case invalidCallback
    case invalidIdentity
    case invalidTokenResponse
    case planPermissionRequired
    case reauthenticationRequired
    case signInTimedOut
    case clientConfigurationRejected
    case accessDenied
    case browserOpenFailed

    public var errorDescription: String? {
        switch self {
        case .notImplemented: return "This connection is not available yet."
        case .notConnected: return "Continue with ChatGPT to connect an account."
        case .signInInProgress: return "A ChatGPT sign-in is already in progress."
        case .remoteRevocationUnconfirmed:
            return "Signed out locally. Remote revocation was not confirmed; disconnect Sable in ChatGPT Settings."
        case .storageUnavailable: return "Sable could not read or save its protected connection files."
        case .invalidKey: return "Enter a nonempty OpenRouter key without control characters."
        case .networkUnavailable: return "ChatGPT is temporarily unreachable. Please try again."
        case .invalidDiscovery: return "OpenAI's sign-in configuration could not be verified."
        case .listenerUnavailable: return "Sable could not start the local sign-in callback."
        case .authorizationFailed: return "ChatGPT sign-in was declined or could not be completed."
        case .invalidCallback: return "The ChatGPT registration callback did not match this sign-in."
        case .invalidIdentity: return "The ChatGPT account identity could not be verified."
        case .invalidTokenResponse: return "ChatGPT returned an unusable connection. Please sign in again."
        case .planPermissionRequired: return "Enable ChatGPT plan usage by continuing with ChatGPT again."
        case .reauthenticationRequired: return "This ChatGPT session has ended. Please sign in again."
        case .signInTimedOut: return "ChatGPT sign-in timed out. Please try again."
        case .clientConfigurationRejected: return "OpenAI rejected this app registration. Check the client configuration before trying again."
        case .accessDenied: return "ChatGPT sign-in was declined. You can continue with ChatGPT again when ready."
        case .browserOpenFailed: return "Sable could not open your browser for ChatGPT sign-in."
        }
    }
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

/// Native public-client OAuth and the sole owner of the active ChatGPT grant.
/// UI sees only account metadata; generation obtains a short-lived bearer per
/// request. One attempt, one refresh task and a file lease guard async handoffs.
public actor ChatGPTConnection: ChatGPTConnecting {
    private let files: ProtectedConnectionFiles
    private let transport: any ConnectionHTTPTransport
    private let clock: ConnectionClock
    private let signInTimeout: TimeInterval
    private let makeListener: @Sendable () -> any ConnectionCallbackListening
    private var archive: ConnectionArchive
    private var loadError: ConnectionError?
    private var attempt: SignInAttempt?
    // Epoch changes synchronously on disconnect/activation. Actor reentrancy
    // alone does not stop an older HTTP completion from committing credentials.
    private var epoch: UInt64 = 0
    private var refresh: (id: UUID, task: Task<ConnectionAccessToken, Error>)?
    private static let resource = "https://api.openai.com/v1"
    private static let identityScopes = ["openid", "profile", "email"]
    private static let planScopes = ["offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]
    private static let usableScopes: Set<String> = ["openid", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]

    private struct SignInAttempt {
        let id: UUID
        let listener: any ConnectionCallbackListening
        let continuation: CheckedContinuation<ConnectionAccount, Error>
        var work: Task<Void, Never>?
        var timeout: Task<Void, Never>?
    }

    public init(locations: ConnectionStorageLocations = .standard(),
                transport: any ConnectionHTTPTransport = URLSessionConnectionTransport(),
                clock: ConnectionClock = ConnectionClock(), signInTimeout: TimeInterval = 180) {
        self.init(locations: locations, transport: transport, clock: clock, signInTimeout: signInTimeout,
                  makeListener: { LoopbackConnectionListener() })
    }

    init(locations: ConnectionStorageLocations, transport: any ConnectionHTTPTransport,
         clock: ConnectionClock = ConnectionClock(), signInTimeout: TimeInterval = 180,
         makeListener: @escaping @Sendable () -> any ConnectionCallbackListening) {
        self.files = ProtectedConnectionFiles(locations: locations)
        self.transport = transport
        self.clock = clock
        self.signInTimeout = max(0.01, min(signInTimeout, 600))
        self.makeListener = makeListener
        do { archive = try ConnectionArchive.read(from: files) ?? ConnectionArchive() }
        catch { archive = ConnectionArchive(); loadError = .storageUnavailable }
    }

    public func status() -> ConnectionStatus {
        ConnectionStatus(activeAccount: archive.active?.account, isSigningIn: attempt != nil,
                         planUsageEnabled: archive.active?.tokens.map { Self.usableScopes.isSubset(of: Set($0.scopes)) } ?? false,
                         needsReconnect: archive.reauthenticationID != nil)
    }

    /// Registrations survive sign-out and are keyed by verified issuer/client/sub,
    /// never email. The optional account overload lets an account picker reauthorize
    /// a saved registration, or explicitly add one with a nil accountID.
    public func savedAccounts() -> [ConnectionAccount] { archive.registrations.map(\.account) }

    @discardableResult
    public func signIn(openBrowser: @escaping ConnectionBrowserOpener) async throws -> ConnectionAccount {
        try await signIn(accountID: archive.selectedID, openBrowser: openBrowser)
    }

    @discardableResult
    public func signIn(accountID: String?, openBrowser: @escaping ConnectionBrowserOpener) async throws -> ConnectionAccount {
        try Task.checkCancellation()
        if let loadError { throw loadError }
        guard attempt == nil else { throw ConnectionError.signInInProgress }
        let selected = accountID.flatMap { id in archive.registrations.first { $0.id == id } }
        guard accountID == nil || selected != nil else { throw ConnectionError.notConnected }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let listener = makeListener()
                attempt = SignInAttempt(id: id, listener: listener, continuation: continuation)
                attempt?.work = Task {
                    do { try await self.authorize(id: id, selected: selected, listener: listener, openBrowser: openBrowser) }
                    catch { self.finishAttempt(id, error: Self.safe(error)) }
                }
                attempt?.timeout = Task {
                    do {
                        try await self.clock.sleep(self.signInTimeout)
                        self.finishAttempt(id, error: ConnectionError.signInTimedOut)
                    } catch { /* A completed/cancelled attempt owns no timeout. */ }
                }
            }
        } onCancel: { Task { await self.cancelAttempt(id) } }
    }

    public func cancelSignIn() { if let id = attempt?.id { cancelAttempt(id) } }

    private func cancelAttempt(_ id: UUID) { finishAttempt(id, error: CancellationError()) }

    private func finishAttempt(_ id: UUID, error: Error) {
        guard let pending = attempt, pending.id == id else { return }
        attempt = nil
        pending.listener.cancel()
        pending.work?.cancel()
        pending.timeout?.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func checkAttempt(_ id: UUID) throws {
        try Task.checkCancellation()
        guard attempt?.id == id else { throw CancellationError() }
    }

    private func authorize(id: UUID, selected: SavedChatGPTRegistration?, listener: any ConnectionCallbackListening,
                           openBrowser: @escaping ConnectionBrowserOpener) async throws {
        let (hostID, lifecycle) = try await prepareHost(for: id)
        let state = try OAuthEncoding.random()
        let nonce = try OAuthEncoding.random()
        let verifier = try OAuthEncoding.random(64)
        let discovery = try await discover()
        try checkAttempt(id)
        let redirect = try await listener.start(state: state)
        try checkAttempt(id)
        var authorization = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var values = ["client_id": selected?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                      "response_type": "code", "redirect_uri": redirect.absoluteString,
                      "scope": (Self.identityScopes + Self.planScopes).joined(separator: " "),
                      "resource": Self.resource, "state": state, "nonce": nonce,
                      "code_challenge_method": "S256",
                      "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL]
        if let selected {
            if let hint = selected.tokens?.idToken { values["id_token_hint"] = hint }
            if let email = selected.email { values["login_hint"] = email }
            // Re-consent is explicit only when the saved identity has no usable
            // plan grant. Routine sign-in must not force a consent screen.
            if selected.tokens == nil { values["prompt"] = "consent" }
        } else { values["agent_name_hint"] = "Sable" }
        authorization.percentEncodedQuery = String(data: OAuthEncoding.form(values), encoding: .utf8)
        guard let url = authorization.url else { throw ConnectionError.authorizationFailed }
        do { try await openBrowser(url) }
        catch { throw Self.safe(error, fallback: .browserOpenFailed) }
        try checkAttempt(id)
        let callback = try await listener.callback()
        try checkAttempt(id)
        if let error = callback.error {
            throw error == "access_denied" ? ConnectionError.accessDenied : ConnectionError.authorizationFailed
        }
        let clientID: String
        if let selected {
            guard callback.clientID == nil || callback.clientID == selected.clientID else {
                throw ConnectionError.invalidCallback
            }
            clientID = selected.clientID
        } else {
            guard let issued = callback.clientID, Self.isIssuedClientID(issued) else { throw ConnectionError.invalidCallback }
            clientID = issued
        }
        guard let code = callback.code, !code.isEmpty else { throw ConnectionError.invalidCallback }
        let response = try await send(OAuthEncoding.post(discovery.tokenEndpoint, values: [
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect.absoluteString, "resource": Self.resource,
        ]))
        let grant = try TokenGrant.decode(response)
        guard let idToken = grant.idToken else { throw ConnectionError.invalidIdentity }
        let jwks = try await keys(discovery)
        let identity = try OpenAIIdentityVerifier.verify(idToken, jwks: jwks, issuer: discovery.issuer,
                                                       clientID: clientID, nonce: nonce, now: clock.now(),
                                                       accessToken: grant.accessToken)
        guard selected == nil || selected?.subject == identity.subject else { throw ConnectionError.invalidIdentity }
        let grantedScopes = Set(grant.scope?.split(whereSeparator: \.isWhitespace).map(String.init) ?? [])
        let tokens = Self.usableScopes.isSubset(of: grantedScopes) ? try grant.tokens(now: clock.now(), previous: nil) : nil
        let registration = SavedChatGPTRegistration(issuer: discovery.issuer, subject: identity.subject,
                                                    clientID: clientID, hostID: hostID,
                                                    name: identity.name, email: identity.email, tokens: tokens)
        let lease = try await files.lock()
        defer { withExtendedLifetime(lease) {} }
        try checkAttempt(id)
        var disk = try ConnectionArchive.read(from: files) ?? ConnectionArchive()
        guard disk.lifecycle == lifecycle else { throw ConnectionError.notConnected }
        if tokens == nil {
            // Preserve the verified registration for re-consent, but never replace
            // a working active account with an identity-only sign-in.
            if !disk.registrations.contains(where: { $0.id == registration.id }) {
                var metadata = registration
                metadata.tokens = nil
                disk.registrations.append(metadata)
                if disk.selectedID == nil { disk.selectedID = metadata.id }
                if disk.activeID == nil && disk.reauthenticationID == nil { disk.activeID = metadata.id }
                try disk.save(to: files)
                archive = disk
            }
            throw ConnectionError.planPermissionRequired
        }
        disk.upsert(registration)
        disk.selectedID = registration.id
        disk.activeID = registration.id
        disk.reauthenticationID = nil
        disk.lifecycle = UUID()
        try disk.save(to: files)
        archive = disk
        epoch &+= 1
        refresh?.task.cancel()
        refresh = nil
        // Committing and resuming are one actor turn. A timeout cannot report
        // cancellation after credentials have already become active.
        guard let pending = attempt, pending.id == id else { return }
        attempt = nil
        pending.timeout?.cancel()
        pending.listener.cancel()
        pending.continuation.resume(returning: registration.account)
    }

    private func prepareHost(for id: UUID) async throws -> (String, UUID) {
        let lease = try await files.lock()
        defer { withExtendedLifetime(lease) {} }
        try checkAttempt(id)
        let host: SavedConnectionHost
        if let data = try files.read(files.locations.hostIdentity) {
            guard let saved = try? JSONDecoder().decode(SavedConnectionHost.self, from: data),
                  saved.id.hasPrefix("urn:uuid:"), UUID(uuidString: String(saved.id.dropFirst(9))) != nil else {
                throw ConnectionError.storageUnavailable
            }
            host = saved
        } else {
            host = SavedConnectionHost(id: "urn:uuid:" + UUID().uuidString.lowercased())
            try files.write(try JSONEncoder().encode(host), to: files.locations.hostIdentity)
        }
        // Persist the empty archive's lifecycle too: cross-process stale-write
        // checks need a stable baseline before the browser is opened.
        let existing = try ConnectionArchive.read(from: files)
        let disk = existing ?? ConnectionArchive()
        if existing == nil { try disk.save(to: files) }
        return (host.id, disk.lifecycle)
    }

    public func accessToken() async throws -> ConnectionAccessToken {
        try Task.checkCancellation()
        let callerEpoch = epoch
        if let loadError { throw loadError }
        guard let active = archive.active else {
            throw archive.reauthenticationID == nil ? ConnectionError.notConnected : ConnectionError.reauthenticationRequired
        }
        guard active.tokens != nil else { throw ConnectionError.planPermissionRequired }
        let id: UUID
        let work: Task<ConnectionAccessToken, Error>
        if let existing = refresh { id = existing.id; work = existing.task }
        else {
            id = UUID()
            let epoch = self.epoch
            let lifecycle = archive.lifecycle
            work = Task { try await self.acquireToken(epoch: epoch, lifecycle: lifecycle, accountID: active.id) }
            refresh = (id, work)
        }
        // All callers share one worker even across its HTTP suspension. One
        // cancelled caller does not cancel refresh for the other callers.
        defer { if refresh?.id == id { refresh = nil } }
        let result = try await work.value
        try Task.checkCancellation()
        guard epoch == callerEpoch, archive.active?.id == result.accountID else { throw ConnectionError.notConnected }
        return result
    }

    private func acquireToken(epoch expectedEpoch: UInt64, lifecycle: UUID, accountID: String) async throws -> ConnectionAccessToken {
        let lease = try await files.lock()
        defer { withExtendedLifetime(lease) {} }
        try checkEpoch(expectedEpoch)
        guard var disk = try ConnectionArchive.read(from: files), disk.lifecycle == lifecycle,
              var active = disk.active, active.id == accountID, let previous = active.tokens else {
            throw ConnectionError.notConnected
        }
        guard Self.usableScopes.isSubset(of: Set(previous.scopes)) else { throw ConnectionError.planPermissionRequired }
        archive = disk
        if previous.expiresAt.timeIntervalSince(clock.now()) > 60 { return active.accessToken(previous) }
        do {
            let discovery = try await discover()
            try checkEpoch(expectedEpoch)
            let response = try await send(OAuthEncoding.post(discovery.tokenEndpoint, values: [
                "grant_type": "refresh_token", "client_id": active.clientID,
                "refresh_token": previous.refreshToken, "resource": Self.resource,
            ]))
            let grant = try TokenGrant.decode(response)
            let tokens = try grant.tokens(now: clock.now(), previous: previous)
            if let idToken = grant.idToken {
                let jwks = try await keys(discovery)
                let identity = try OpenAIIdentityVerifier.verify(idToken, jwks: jwks, issuer: active.issuer,
                                                               clientID: active.clientID, nonce: nil, now: clock.now(),
                                                               accessToken: tokens.accessToken)
                guard identity.subject == active.subject else { throw ConnectionError.invalidIdentity }
            }
            try checkEpoch(expectedEpoch)
            guard Self.usableScopes.isSubset(of: Set(tokens.scopes)) else { throw ConnectionError.planPermissionRequired }
            active.tokens = tokens
            disk.upsert(active)
            try disk.save(to: files)
            archive = disk
            return active.accessToken(tokens)
        } catch {
            try checkEpoch(expectedEpoch)
            let safe = Self.safe(error)
            if safe as? ConnectionError == .reauthenticationRequired || safe as? ConnectionError == .planPermissionRequired {
                // Terminal provider evidence alone clears tokens. Timeouts,
                // malformed responses and 5xx preserve the last durable grant.
                active.tokens = nil
                disk.upsert(active)
                disk.activeID = nil
                disk.reauthenticationID = active.id
                disk.lifecycle = UUID()
                try disk.save(to: files)
                archive = disk
                self.epoch &+= 1
            }
            throw safe
        }
    }

    private func checkEpoch(_ expected: UInt64) throws {
        guard epoch == expected, !Task.isCancelled else { throw ConnectionError.notConnected }
    }

    public func disconnect() async throws {
        // Local clearing must complete even if the caller abandons its UI task.
        // A bounded, unstructured operation owns this cleanup independently.
        let work = Task { try await self.disconnectSession() }
        try await work.value
    }

    private func disconnectSession() async throws {
        cancelSignIn()
        epoch &+= 1
        let expectedEpoch = epoch
        let expectedLifecycle = archive.lifecycle
        refresh?.task.cancel()
        refresh = nil
        let selectedID = archive.activeID ?? archive.selectedID
        archive.activeID = nil
        if let selectedID, let index = archive.registrations.firstIndex(where: { $0.id == selectedID }) {
            archive.registrations[index].tokens = nil
        }
        if let loadError { throw loadError }
        let revocation: (client: String, token: String)?
        do {
            let lease = try await files.lock()
            defer { withExtendedLifetime(lease) {} }
            guard epoch == expectedEpoch else { return }
            var disk = try ConnectionArchive.read(from: files) ?? archive
            // Clear the selected session only; a separate process may already
            // have activated another registration while this lease was pending.
            guard disk.lifecycle == expectedLifecycle,
                  disk.activeID == nil || disk.activeID == selectedID else { throw ConnectionError.notConnected }
            if let selectedID, let index = disk.registrations.firstIndex(where: { $0.id == selectedID }) {
                let saved = disk.registrations[index]
                revocation = saved.tokens.map { (saved.clientID, $0.refreshToken) }
                disk.registrations[index].tokens = nil
            } else { revocation = nil }
            disk.activeID = nil
            disk.reauthenticationID = nil
            disk.lifecycle = UUID()
            try disk.save(to: files)
            archive = disk
        }
        guard let revocation else { return }
        // No writes after HTTP: a later sign-in can safely commit while remote
        // revocation is pending, and its tokens will never be cleared by this one.
        do {
            let discovery = try await discover()
            guard let endpoint = discovery.revocationEndpoint else { throw ConnectionError.remoteRevocationUnconfirmed }
            for retry in 0..<2 {
                do {
                    let response = try await send(OAuthEncoding.post(endpoint, values: [
                        "token": revocation.token, "token_type_hint": "refresh_token", "client_id": revocation.client,
                    ]))
                    if response.statusCode == 200 { return }
                    if response.statusCode < 500 { break }
                } catch { /* Network failures get one bounded retry. */ }
                if retry == 0 { try await clock.sleep(0.25) }
            }
        } catch { /* The UI must distinguish local sign-out from confirmed revocation. */ }
        throw ConnectionError.remoteRevocationUnconfirmed
    }

    private func discover() async throws -> OpenAIDiscovery {
        let response = try await send(URLRequest(url: OpenAIDiscovery.url))
        guard response.statusCode == 200, let discovery = try? JSONDecoder().decode(OpenAIDiscovery.self, from: response.data) else {
            throw ConnectionError.invalidDiscovery
        }
        try discovery.validate()
        return discovery
    }

    private func keys(_ discovery: OpenAIDiscovery) async throws -> Data {
        // Fetching per verification handles unknown/rotated kid without an
        // unbounded or stale JWKS cache. This is never a URL from the JWT header.
        let response = try await send(URLRequest(url: discovery.jwksURI))
        guard response.statusCode == 200 else { throw ConnectionError.networkUnavailable }
        return response.data
    }

    private func send(_ request: URLRequest) async throws -> ConnectionHTTPResponse {
        do {
            let response = try await transport.send(request)
            try Task.checkCancellation()
            guard response.data.count <= 1_048_576 else { throw ConnectionError.invalidTokenResponse }
            return response
        } catch { throw Self.safe(error) }
    }

    private static func safe(_ error: Error, fallback: ConnectionError = .networkUnavailable) -> Error {
        if error is CancellationError { return CancellationError() }
        return (error as? ConnectionError) ?? fallback
    }

    fileprivate static func isIssuedClientID(_ value: String) -> Bool {
        !value.isEmpty && value != "dynamic_agent_client" && value.utf8.count <= 512
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }
    }
}

private struct SavedConnectionHost: Codable { let id: String }

/// A single protected archive commits rotating tokens together with identity and
/// selected registration. lifecycle changes only on activation/disconnection,
/// allowing concurrent refreshes to reread rotation without reviving old sessions.
private struct ConnectionArchive: Codable {
    var lifecycle = UUID()
    var registrations: [SavedChatGPTRegistration] = []
    var activeID: String?
    var selectedID: String?
    var reauthenticationID: String?
    var active: SavedChatGPTRegistration? {
        registrations.first { $0.id == activeID }
    }

    mutating func upsert(_ value: SavedChatGPTRegistration) {
        if let index = registrations.firstIndex(where: { $0.id == value.id }) { registrations[index] = value }
        else { registrations.append(value) }
    }

    static func read(from files: ProtectedConnectionFiles) throws -> Self? {
        guard let data = try files.read(files.locations.chatGPTCredentials) else { return nil }
        guard let archive = try? JSONDecoder().decode(Self.self, from: data),
              Set(archive.registrations.map(\.id)).count == archive.registrations.count,
              archive.registrations.allSatisfy({ $0.issuer == OpenAIDiscovery.issuer && !$0.subject.isEmpty
                  && ChatGPTConnection.isIssuedClientID($0.clientID) }),
              archive.activeID == nil || archive.active != nil,
              archive.selectedID == nil || archive.registrations.contains(where: { $0.id == archive.selectedID }) else {
            throw ConnectionError.storageUnavailable
        }
        if !archive.registrations.isEmpty {
            guard let data = try files.read(files.locations.hostIdentity),
                  let host = try? JSONDecoder().decode(SavedConnectionHost.self, from: data),
                  archive.registrations.allSatisfy({ $0.hostID == host.id }) else { throw ConnectionError.storageUnavailable }
        }
        return archive
    }

    func save(to files: ProtectedConnectionFiles) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try files.write(encoder.encode(self), to: files.locations.chatGPTCredentials)
        }
        catch { throw ConnectionError.storageUnavailable }
    }
}

private struct SavedChatGPTRegistration: Codable {
    let issuer: String
    let subject: String
    let clientID: String
    let hostID: String
    let name: String?
    let email: String?
    var tokens: SavedChatGPTTokens?
    var id: String { Data(SHA256.hash(data: Data([issuer, clientID, subject].joined(separator: "\n").utf8))).base64URL }
    var account: ConnectionAccount {
        ConnectionAccount(id: id, displayName: (name ?? email ?? "ChatGPT") + " · " + String(id.suffix(6)), email: email)
    }
    func accessToken(_ tokens: SavedChatGPTTokens) -> ConnectionAccessToken {
        ConnectionAccessToken(secret: ConnectionSecret(tokens.accessToken), expiresAt: tokens.expiresAt, accountID: id)
    }
}

private struct SavedChatGPTTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let expiresAt: Date
    let scopes: [String]
}

/// Provider token JSON never crosses the module boundary. Only stable OAuth
/// error codes drive recovery; error_description and arbitrary bodies are ignored.
private struct TokenGrant: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let tokenType: String?
    let expiresIn: Double?
    let scope: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
        case tokenType = "token_type", expiresIn = "expires_in", scope
    }

    static func decode(_ response: ConnectionHTTPResponse) throws -> Self {
        guard response.statusCode == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any])?["error"] as? String
            let terminal: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                                         "refresh_token_invalidated", "refresh_token_reused"]
            if let error, terminal.contains(error) { throw ConnectionError.reauthenticationRequired }
            if error == "invalid_client" { throw ConnectionError.clientConfigurationRejected }
            throw ConnectionError.networkUnavailable
        }
        guard let grant = try? JSONDecoder().decode(Self.self, from: response.data) else {
            throw ConnectionError.invalidTokenResponse
        }
        return grant
    }

    func tokens(now: Date, previous: SavedChatGPTTokens?) throws -> SavedChatGPTTokens {
        guard tokenType?.lowercased() == "bearer", let accessToken, !accessToken.isEmpty, accessToken.utf8.count <= 65_536,
              !accessToken.contains(where: { $0.isWhitespace || $0.isNewline }),
              let expiresIn, expiresIn.isFinite, expiresIn > 0, expiresIn <= 31_536_000,
              let refresh = refreshToken ?? previous?.refreshToken, !refresh.isEmpty,
              let id = idToken ?? previous?.idToken, !id.isEmpty else { throw ConnectionError.invalidTokenResponse }
        let scopes = scope.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) } ?? previous?.scopes ?? []
        return SavedChatGPTTokens(accessToken: accessToken, refreshToken: refresh, idToken: id,
                                  expiresAt: now.addingTimeInterval(expiresIn), scopes: scopes)
    }
}
