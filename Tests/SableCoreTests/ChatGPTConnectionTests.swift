import XCTest
import CryptoKit
import Security
@testable import SableCore

/// All credentials are synthetic, all files are disposable, and browser opening
/// is a protocol callback. No test visits OpenAI, another app, or owner config.
final class ChatGPTConnectionTests: XCTestCase {
    func testNativeRegistrationPKCEVerifiedIdentityAndProtectedRestart() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        let account = try await rig.signIn()
        assertEqual(account.email, "sable+test@example.test")
        let requests = await rig.server.authorizationRequests
        let authorization = try unwrap(requests.first)
        assertEqual(authorization["client_id"], "dynamic_agent_client")
        assertEqual(authorization["agent_name_hint"], "Sable")
        assertEqual(authorization["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        assertEqual(authorization["code_challenge_method"], "S256")
        assertEqual(authorization["resource"], "https://api.openai.com/v1")
        let exchange = try unwrap(await rig.server.exchanges.first)
        assertEqual(exchange["client_id"], "oaiapp_sableA")
        assertNil(exchange["client_secret"])
        assertEqual(exchange["redirect_uri"], authorization["redirect_uri"])
        let verifier = try unwrap(exchange["code_verifier"])
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        assertEqual(Data(SHA256.hash(data: Data(verifier.utf8))).base64URL, authorization["code_challenge"])
        let host = try Data(contentsOf: rig.locations.hostIdentity)
        XCTAssertTrue(rig.pool.last!.cancelled)
        assertEqual(try permissions(rig.locations.directory), 0o700)
        assertEqual(try permissions(rig.locations.hostIdentity), 0o600)
        assertEqual(try permissions(rig.locations.chatGPTCredentials), 0o600)

        let restarted = rig.connection()
        let status = await restarted.status()
        assertEqual(status.activeAccount, account)
        let token = try await restarted.accessToken()
        assertEqual(token.accountID, account.id)
        assertEqual(token.secret.rawValue, "access-1")
        _ = try await rig.signIn(connection: restarted)
        let returning = try unwrap(await rig.server.authorizationRequests.last)
        assertEqual(returning["client_id"], "oaiapp_sableA")
        assertNil(returning["agent_name_hint"])
        XCTAssertNotNil(returning["id_token_hint"])
        assertEqual(returning["login_hint"], "sable+test@example.test")
        XCTAssertNotEqual(authorization["state"], returning["state"])
        XCTAssertNotEqual(authorization["nonce"], returning["nonce"])
        XCTAssertNotEqual(authorization["code_challenge"], returning["code_challenge"])
        assertEqual(try Data(contentsOf: rig.locations.hostIdentity), host)
    }

    func testIdentityFailuresKeepPreviouslyVerifiedAccountAndBytes() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        let account = try await rig.signIn()
        let original = try Data(contentsOf: rig.locations.chatGPTCredentials)
        for mutation in [IdentityMutation.signature, .nonce, .issuer, .audience, .expiry, .subject, .futureIssuedAt,
                         .missingSubject, .algorithm, .keyID, .accessHash, .multipleAudiences] {
            await rig.server.setMutation(mutation)
            await expect(.invalidIdentity) { _ = try await rig.signIn() }
            let status = await rig.client.status()
            assertEqual(status.activeAccount, account, "mutation: \(mutation)")
            assertFalse(status.isSigningIn)
            assertEqual(try Data(contentsOf: rig.locations.chatGPTCredentials), original)
        }
    }

    func testIssuedClientMismatchAndDynamicClientCannotBeExchanged() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        await expect(.invalidCallback) { _ = try await rig.signIn(callbackClientID: "dynamic_agent_client") }
        await expect(.invalidCallback) { _ = try await rig.signIn(callbackClientID: nil) }
        assertEqual(await rig.server.exchangeCount, 0)
        let account = try await rig.signIn()
        let original = try Data(contentsOf: rig.locations.chatGPTCredentials)
        await expect(.invalidCallback) { _ = try await rig.signIn(callbackClientID: "oaiapp_different") }
        assertEqual(await rig.server.exchangeCount, 1)
        assertEqual(await rig.client.status().activeAccount, account)
        assertEqual(try Data(contentsOf: rig.locations.chatGPTCredentials), original)
        _ = try await rig.signIn(callbackClientID: nil) // Returning callback may omit it.
    }

    func testDeniedPlanScopeRetainsMappingAndReconsentUsesIssuedClient() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        await rig.server.setScopes("openid profile email")
        await expect(.planPermissionRequired) { _ = try await rig.signIn() }
        let identityOnly = await rig.client.status()
        XCTAssertNotNil(identityOnly.activeAccount)
        assertFalse(identityOnly.planUsageEnabled)
        assertFalse(identityOnly.needsReconnect)
        let saved = await rig.client.savedAccounts()
        assertEqual(saved.count, 1)
        let bytes = try String(contentsOf: rig.locations.chatGPTCredentials)
        assertFalse(bytes.contains("access-1"))
        await expect(.planPermissionRequired) { _ = try await rig.client.accessToken() }
        await rig.server.setScopes(AuthServer.scopes)
        _ = try await rig.signIn()
        let request = try unwrap(await rig.server.authorizationRequests.last)
        assertEqual(request["client_id"], "oaiapp_sableA")
        assertEqual(request["prompt"], "consent")
        assertEqual(request["scope"], AuthServer.scopes)
    }

    func testDeniedReplacementAndBrowserFailurePreserveActiveConnection() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        let account = try await rig.signIn()
        let original = try Data(contentsOf: rig.locations.chatGPTCredentials)
        await rig.server.setScopes("openid profile email offline_access")
        await expect(.planPermissionRequired) { _ = try await rig.signIn() }
        await expect(.browserOpenFailed) {
            _ = try await rig.client.signIn { _ in throw SecretTestError() }
        }
        let status = await rig.client.status()
        assertEqual(status.activeAccount, account)
        assertFalse(status.isSigningIn)
        assertEqual(try Data(contentsOf: rig.locations.chatGPTCredentials), original)
    }

    func testCancelAndTimeoutResumeOnceAndLeaveExistingAccount() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        let account = try await rig.signIn()
        let original = try Data(contentsOf: rig.locations.chatGPTCredentials)
        let opened = AsyncGate()
        let pending = Task {
            try await rig.client.signIn { _ in await opened.open() }
        }
        await opened.wait()
        let status = await rig.client.status()
        assertEqual(status.activeAccount, account)
        XCTAssertTrue(status.isSigningIn)
        await expect(.signInInProgress) { _ = try await rig.signIn() }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        await rig.client.cancelSignIn() // A second cancellation must not resume again.
        XCTAssertTrue(rig.pool.last!.cancelled)
        assertEqual(try Data(contentsOf: rig.locations.chatGPTCredentials), original)

        let timer = AsyncGate()
        let timeoutClock = ConnectionClock(now: { rig.time.now }, sleep: { _ in await timer.wait() })
        let timed = rig.connection(clock: timeoutClock)
        let timedOpened = AsyncGate()
        let task = Task { try await timed.signIn { _ in await timedOpened.open() } }
        await timedOpened.wait()
        await timer.open()
        await expect(.signInTimedOut) { _ = try await task.value }
        XCTAssertTrue(rig.pool.last!.cancelled)
        assertEqual(await timed.status().activeAccount, account)
        assertEqual(try Data(contentsOf: rig.locations.chatGPTCredentials), original)
    }

    func testCancellationResumesEvenIfBrowserOpenerHasNotReturned() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        let entered = AsyncGate()
        let release = AsyncGate()
        let pending = Task {
            try await rig.client.signIn { _ in
                await entered.open()
                await release.wait()
            }
        }
        await entered.wait()
        await rig.client.cancelSignIn()
        do { _ = try await pending.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        assertFalse(await rig.client.status().isSigningIn)
        await release.open()
    }

    func testRefreshCoalescesConcurrentCallersAndRotatesWholeGrant() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        _ = try await rig.signIn()
        rig.time.advance(3_550)
        let gate = AsyncGate()
        await rig.server.holdRefresh(gate)
        let callers = (0..<20).map { _ in Task { try await rig.client.accessToken() } }
        try await eventually { await rig.server.refreshCount == 1 }
        await gate.open()
        for caller in callers { assertEqual(try await caller.value.secret.rawValue, "access-2") }
        assertEqual(await rig.server.refreshCount, 1)
        let saved = try String(contentsOf: rig.locations.chatGPTCredentials)
        XCTAssertTrue(saved.contains("refresh-2"))
        assertFalse(saved.contains("refresh-1"))
        XCTAssertTrue(saved.contains("access-2"))
        let request = try unwrap(await rig.server.refreshRequests.last)
        assertEqual(request["client_id"], "oaiapp_sableA")
        assertEqual(request["resource"], "https://api.openai.com/v1")
        assertNil(request["scope"])

        rig.time.advance(3_550)
        let restarted = rig.connection()
        _ = try await restarted.accessToken()
        assertEqual(await rig.server.refreshRequests.last?["refresh_token"], "refresh-2")
    }

    func testSeparateInstancesSerializeRotationAndRereadLatestGrant() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        _ = try await rig.signIn()
        let second = rig.connection()
        rig.time.advance(3_550)
        let gate = AsyncGate()
        await rig.server.holdRefresh(gate)
        let first = Task { try await rig.client.accessToken() }
        try await eventually { await rig.server.refreshCount == 1 }
        let other = Task { try await second.accessToken() }
        await gate.open()
        assertEqual(try await first.value.secret.rawValue, "access-2")
        assertEqual(try await other.value.secret.rawValue, "access-2")
        assertEqual(await rig.server.refreshCount, 1)
    }

    func testTemporaryRefreshFailuresPreserveCredentialsAndTerminalGrantClearsOnlyTokens() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        let account = try await rig.signIn()
        rig.time.advance(3_550)
        let original = try Data(contentsOf: rig.locations.chatGPTCredentials)
        await rig.server.setRefreshFailure(.temporary)
        await expect(.networkUnavailable) { _ = try await rig.client.accessToken() }
        assertEqual(try Data(contentsOf: rig.locations.chatGPTCredentials), original)
        assertEqual(await rig.client.status().activeAccount, account)
        await rig.server.setRefreshFailure(.terminal)
        await expect(.reauthenticationRequired) { _ = try await rig.client.accessToken() }
        assertNil(await rig.client.status().activeAccount)
        let ended = await rig.client.status()
        XCTAssertTrue(ended.needsReconnect)
        let saved = try String(contentsOf: rig.locations.chatGPTCredentials)
        assertFalse(saved.contains("access-1"))
        assertFalse(saved.contains("refresh-1"))
        XCTAssertTrue(saved.contains("oaiapp_sableA"))
        assertEqual(await rig.client.savedAccounts(), [account])
        await expect(.reauthenticationRequired) { _ = try await rig.client.accessToken() }
    }

    func testSignOutDuringRefreshPreventsStaleWriteAndRevokesRotatingToken() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        _ = try await rig.signIn()
        let host = try Data(contentsOf: rig.locations.hostIdentity)
        rig.time.advance(3_550)
        let gate = AsyncGate()
        await rig.server.holdRefresh(gate)
        let refresh = Task { try await rig.client.accessToken() }
        try await eventually { await rig.server.refreshCount == 1 }
        let disconnect = Task { try await rig.client.disconnect() }
        try await eventually { await rig.client.status().activeAccount == nil }
        await gate.open() // Deliberately returns despite cancelled task.
        await expect(.notConnected) { _ = try await refresh.value }
        try await disconnect.value
        let saved = try String(contentsOf: rig.locations.chatGPTCredentials)
        assertFalse(saved.contains("access-"))
        assertFalse(saved.contains("refresh-"))
        assertEqual(try Data(contentsOf: rig.locations.hostIdentity), host)
        assertEqual(await rig.server.revocations.last?["token"], "refresh-2")
        let restarted = rig.connection()
        assertNil(await restarted.status().activeAccount)
        _ = try await rig.signIn(connection: restarted)
        let request = try unwrap(await rig.server.authorizationRequests.last)
        assertEqual(request["client_id"], "oaiapp_sableA")
        assertNil(request["id_token_hint"])
    }

    func testPendingRevocationNeverClearsNewSignIn() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        _ = try await rig.signIn()
        let gate = AsyncGate()
        await rig.server.holdRevocation(gate)
        let disconnect = Task { try await rig.client.disconnect() }
        try await eventually { await rig.server.revocations.count == 1 }
        let account = try await rig.signIn()
        let current = try Data(contentsOf: rig.locations.chatGPTCredentials)
        await gate.open()
        try await disconnect.value
        assertEqual(await rig.client.status().activeAccount, account)
        assertEqual(try Data(contentsOf: rig.locations.chatGPTCredentials), current)
    }

    func testRevocationFailureReportsNonsecretOutcomeAndClearsTokens() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        _ = try await rig.signIn()
        await rig.server.setRevocationStatus(503)
        await expect(.remoteRevocationUnconfirmed) { try await rig.client.disconnect() }
        assertEqual(await rig.server.revocations.count, 2)
        assertNil(await rig.client.status().activeAccount)
        assertFalse(try String(contentsOf: rig.locations.chatGPTCredentials).contains("refresh-1"))
        assertFalse(ConnectionError.remoteRevocationUnconfirmed.localizedDescription.contains("refresh-1"))
    }

    func testUntrustedDiscoveryNeverGetsAuthorizationOrCredentials() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        await rig.server.setUntrustedDiscovery(true)
        await expect(.invalidDiscovery) { _ = try await rig.signIn() }
        assertEqual(await rig.server.authorizationRequests.count, 0)
        assertEqual(await rig.server.exchangeCount, 0)
    }

    func testIndependentRegistrationsWithSameEmailAndExplicitNewAccount() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        let first = try await rig.signIn()
        await rig.server.setIssuedClient("oaiapp_sableB")
        let second = try await rig.signIn(newAccount: true, callbackClientID: "oaiapp_sableB")
        assertEqual(first.email, second.email)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.displayName, second.displayName)
        assertEqual(await rig.client.savedAccounts().count, 2)
    }

    func testIdentityOnlyResponseDoesNotRequireInferenceTokens() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        await rig.server.setIdentityOnly(true)
        await expect(.planPermissionRequired) { _ = try await rig.signIn() }
        let status = await rig.client.status()
        XCTAssertNotNil(status.activeAccount)
        assertFalse(status.planUsageEnabled)
        let saved = try String(contentsOf: rig.locations.chatGPTCredentials)
        assertFalse(saved.contains("access-1"))
        assertFalse(saved.contains("refresh-1"))
    }

    func testOneCancelledRefreshCallerDoesNotCancelOtherCallers() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        _ = try await rig.signIn()
        rig.time.advance(3_550)
        let gate = AsyncGate()
        await rig.server.holdRefresh(gate)
        let cancelled = Task { try await rig.client.accessToken() }
        try await eventually { await rig.server.refreshCount == 1 }
        let remaining = Task { try await rig.client.accessToken() }
        cancelled.cancel()
        await gate.open()
        do { _ = try await cancelled.value; XCTFail("Expected cancelled caller") } catch { XCTAssertTrue(error is CancellationError) }
        assertEqual(try await remaining.value.secret.rawValue, "access-2")
        assertEqual(await rig.server.refreshCount, 1)
    }

    func testNativeListenerTimeoutClosesPortWithoutBrowserLaunch() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        let connection = ChatGPTConnection(locations: rig.locations, transport: rig.server,
                                           clock: ConnectionClock(now: { rig.time.now }), signInTimeout: 0.05)
        let capture = CallbackURLCapture()
        await expect(.signInTimedOut) {
            _ = try await connection.signIn { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                await capture.set(URL(string: items.first { $0.name == "redirect_uri" }!.value!)!)
            }
        }
        let url = try unwrap(await capture.url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do { _ = try await session.data(from: url); XCTFail("Timed-out listener must be closed") } catch {}
        assertFalse(await connection.status().isSigningIn)
    }

    func testInvalidClientIsActionableAndDoesNotEraseDurableGrant() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        _ = try await rig.signIn()
        rig.time.advance(3_550)
        let original = try Data(contentsOf: rig.locations.chatGPTCredentials)
        await rig.server.setRefreshFailure(.invalidClient)
        await expect(.clientConfigurationRejected) { _ = try await rig.client.accessToken() }
        assertEqual(try Data(contentsOf: rig.locations.chatGPTCredentials), original)
    }

    func testLostRefreshResponseMakesRevocationExplicitlyUnconfirmed() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        _ = try await rig.signIn()
        rig.time.advance(3_550)
        await rig.server.setRefreshFailure(.temporary)
        await expect(.networkUnavailable) { _ = try await rig.client.accessToken() }
        await expect(.remoteRevocationUnconfirmed) { try await rig.client.disconnect() }
        assertNil(await rig.client.status().activeAccount)
        assertEqual(await rig.server.revocations.last?["token"], "refresh-1")
    }

    func testExpiredAuthorizationCodeRetriesWithIssuedClientAndFreshTransaction() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        await rig.server.expireFirstCode()
        _ = try await rig.signIn()
        let requests = await rig.server.authorizationRequests
        assertEqual(requests.count, 2)
        assertEqual(requests[0]["client_id"], "dynamic_agent_client")
        assertEqual(requests[1]["client_id"], "oaiapp_sableA")
        assertNil(requests[1]["agent_name_hint"])
        XCTAssertNotEqual(requests[0]["state"], requests[1]["state"])
        XCTAssertNotEqual(requests[0]["nonce"], requests[1]["nonce"])
        XCTAssertNotEqual(requests[0]["code_challenge"], requests[1]["code_challenge"])
        assertEqual(await rig.server.exchanges.map { $0["client_id"] }, ["oaiapp_sableA", "oaiapp_sableA"])
    }

    func testJWKSOutageRetainsPendingRotationAndValidatesItAfterRestart() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        _ = try await rig.signIn()
        rig.time.advance(3_550)
        await rig.server.setJWKSFailure(true)
        await expect(.networkUnavailable) { _ = try await rig.client.accessToken() }
        let pending = try String(contentsOf: rig.locations.chatGPTCredentials)
        XCTAssertTrue(pending.contains("pendingRefresh"))
        XCTAssertTrue(pending.contains("refresh-2"))
        let restarted = rig.connection()
        await expect(.networkUnavailable) { _ = try await restarted.accessToken() }
        assertEqual(await rig.server.refreshCount, 1)
        await rig.server.setJWKSFailure(false)
        assertEqual(try await restarted.accessToken().secret.rawValue, "access-2")
        assertEqual(await rig.server.refreshCount, 1)
        let committed = try String(contentsOf: rig.locations.chatGPTCredentials)
        assertFalse(committed.contains("pendingRefresh"))
        assertFalse(committed.contains("refresh-1"))
        XCTAssertTrue(committed.contains("refresh-2"))
    }

    func testExpiredPendingGrantRecoversWithLatestRefreshToken() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        _ = try await rig.signIn()
        rig.time.advance(3_550)
        await rig.server.setJWKSFailure(true)
        await expect(.networkUnavailable) { _ = try await rig.client.accessToken() }
        rig.time.advance(4_000)
        await rig.server.setJWKSFailure(false)
        let restarted = rig.connection()
        assertEqual(try await restarted.accessToken().secret.rawValue, "access-3")
        assertEqual(await rig.server.refreshRequests.last?["refresh_token"], "refresh-2")
        assertEqual(await rig.server.refreshCount, 2)
    }

    func testDisconnectAfterRestartRevokesProtectedPendingRotation() async throws {
        let rig = try AuthRig()
        defer { rig.remove() }
        _ = try await rig.signIn()
        rig.time.advance(3_550)
        await rig.server.setJWKSFailure(true)
        await expect(.networkUnavailable) { _ = try await rig.client.accessToken() }
        let restarted = rig.connection()
        try await restarted.disconnect()
        assertEqual(await rig.server.revocations.last?["token"], "refresh-2")
        let saved = try String(contentsOf: rig.locations.chatGPTCredentials)
        assertFalse(saved.contains("pendingRefresh"))
        assertFalse(saved.contains("refresh-"))
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }
}

private enum IdentityMutation { case none, signature, nonce, issuer, audience, expiry, subject, futureIssuedAt,
    missingSubject, algorithm, keyID, accessHash, multipleAudiences }
private enum RefreshFailure { case none, temporary, terminal, invalidClient }
private struct SecretTestError: Error, CustomStringConvertible { var description: String { "synthetic-secret-never-display" } }

private func expect(_ expected: ConnectionError, operation: () async throws -> Void,
                    file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { assertEqual(error as? ConnectionError, expected, file: file, line: line) }
}

private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Condition did not become true", file: file, line: line)
    throw ConnectionError.signInTimedOut
}

/// A gate deliberately ignores cancellation so race tests prove stale-operation
/// rejection rather than merely depending on a cooperative mock HTTP transport.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private actor CallbackURLCapture {
    var url: URL?
    func set(_ value: URL) { url = value }
}

private final class TestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private final class StubCallbackListener: ConnectionCallbackListening, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<ConnectionCallback, Error>?
    private var waiter: CheckedContinuation<ConnectionCallback, Error>?
    private var didCancel = false
    var cancelled: Bool { lock.withLock { didCancel } }
    func start(state: String) async throws -> URL { URL(string: "http://127.0.0.1:54321/auth/callback")! }
    func callback() async throws -> ConnectionCallback {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let result { continuation.resume(with: result) } else { waiter = continuation }
            }
        }
    }
    func deliver(_ callback: ConnectionCallback) { complete(.success(callback)) }
    func cancel() { lock.withLock { didCancel = true }; complete(.failure(CancellationError())) }
    private func complete(_ value: Result<ConnectionCallback, Error>) {
        lock.withLock {
            guard result == nil else { return }
            result = value
            waiter?.resume(with: value)
            waiter = nil
        }
    }
}

private final class ListenerPool: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [StubCallbackListener] = []
    var last: StubCallbackListener? { lock.withLock { listeners.last } }
    func make() -> any ConnectionCallbackListening {
        lock.withLock { let listener = StubCallbackListener(); listeners.append(listener); return listener }
    }
}

private final class AuthRig: @unchecked Sendable {
    let locations: ConnectionStorageLocations
    let time = TestTime()
    let pool = ListenerPool()
    let server: AuthServer
    lazy var client = connection()
    init() throws {
        locations = ConnectionStorageLocations(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("sable-auth-tests-\(UUID().uuidString)", isDirectory: true))
        server = AuthServer(time: time)
    }
    func connection(clock: ConnectionClock? = nil) -> ChatGPTConnection {
        ChatGPTConnection(locations: locations, transport: server, clock: clock ?? ConnectionClock(now: { self.time.now }),
                          makeListener: { self.pool.make() })
    }
    func signIn(connection: ChatGPTConnection? = nil, newAccount: Bool = false,
                callbackClientID: String? = "oaiapp_sableA") async throws -> ConnectionAccount {
        let target = connection ?? client
        let opener: ConnectionBrowserOpener = { url in
            // Host persistence must have happened before browser injection.
            XCTAssertTrue(FileManager.default.fileExists(atPath: self.locations.hostIdentity.path))
            await self.server.openBrowser(url)
            self.pool.last!.deliver(ConnectionCallback(code: "authorization+code", clientID: callbackClientID, error: nil))
        }
        if newAccount { return try await target.signIn(accountID: nil, openBrowser: opener) }
        return try await target.signIn(openBrowser: opener)
    }
    func remove() { try? FileManager.default.removeItem(at: locations.directory) }
}

/// Fake OpenAI issuer that signs real P-256 JWTs and records only synthetic form
/// requests. It can suspend refresh/revocation at the exact async ownership seam.
private actor AuthServer: ConnectionHTTPTransport {
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    let time: TestTime
    let signingKey = P256.Signing.PrivateKey()
    var authorizationRequests: [[String: String]] = []
    var exchanges: [[String: String]] = []
    var refreshRequests: [[String: String]] = []
    var revocations: [[String: String]] = []
    var exchangeCount: Int { exchanges.count }
    var refreshCount: Int { refreshRequests.count }
    private var nonce = ""
    private var issuedClient = "oaiapp_sableA"
    private var scopes = AuthServer.scopes
    private var mutation = IdentityMutation.none
    private var refreshFailure = RefreshFailure.none
    private var sequence = 0
    private var refreshGate: AsyncGate?
    private var revocationGate: AsyncGate?
    private var revocationStatus = 200
    private var untrustedDiscovery = false
    private var identityOnly = false
    private var firstCodeExpires = false
    private var jwksFailure = false

    init(time: TestTime) { self.time = time }
    func setMutation(_ value: IdentityMutation) { mutation = value }
    func setIssuedClient(_ value: String) { issuedClient = value }
    func setScopes(_ value: String) { scopes = value }
    func setRefreshFailure(_ value: RefreshFailure) { refreshFailure = value }
    func setRevocationStatus(_ value: Int) { revocationStatus = value }
    func setUntrustedDiscovery(_ value: Bool) { untrustedDiscovery = value }
    func setIdentityOnly(_ value: Bool) { identityOnly = value; if value { scopes = "openid profile email" } }
    func expireFirstCode() { firstCodeExpires = true }
    func setJWKSFailure(_ value: Bool) { jwksFailure = value }
    func holdRefresh(_ gate: AsyncGate) { refreshGate = gate }
    func holdRevocation(_ gate: AsyncGate) { revocationGate = gate }
    func openBrowser(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value!) })
        authorizationRequests.append(values)
        nonce = values["nonce"]!
    }

    func send(_ request: URLRequest) async throws -> ConnectionHTTPResponse {
        let path = request.url!.path
        if path == "/.well-known/openid-configuration" {
            return try json(["issuer": OpenAIDiscovery.issuer,
                             "authorization_endpoint": "https://auth.openai.com/api/accounts/authorize",
                             "token_endpoint": "https://auth.openai.com/api/accounts/oauth/token",
                             "jwks_uri": untrustedDiscovery ? "https://untrusted.test/keys" : "https://auth.openai.com/.well-known/jwks.json",
                             "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke"])
        }
        if path == "/.well-known/jwks.json" {
            if jwksFailure { return ConnectionHTTPResponse(statusCode: 503, data: Data()) }
            let key = signingKey.publicKey.x963Representation
            return try json(["keys": [["kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": "test-key",
                                       "x": Data(key[1..<33]).base64URL, "y": Data(key[33..<65]).base64URL]]])
        }
        let form = decodeForm(request.httpBody!)
        if path == "/api/accounts/oauth/revoke" {
            revocations.append(form)
            if let gate = revocationGate { await gate.wait() }
            return ConnectionHTTPResponse(statusCode: revocationStatus, data: Data())
        }
        assertEqual(path, "/api/accounts/oauth/token")
        if form["grant_type"] == "refresh_token" {
            refreshRequests.append(form)
            if let gate = refreshGate { await gate.wait() }
            if refreshFailure == .temporary { throw SecretTestError() }
            if refreshFailure == .terminal { return try json(["error": "invalid_grant", "error_description": "synthetic-secret"], status: 400) }
            if refreshFailure == .invalidClient { return try json(["error": "invalid_client"], status: 401) }
        } else {
            exchanges.append(form)
            if firstCodeExpires && exchanges.count == 1 { return try json(["error": "invalid_grant"], status: 400) }
        }
        sequence += 1
        let access = "access-\(sequence)"
        let jwt = try identity(access: access)
        if identityOnly { return try json(["id_token": jwt, "scope": scopes]) }
        return try json(["access_token": access, "refresh_token": "refresh-\(sequence)", "id_token": jwt,
                         "token_type": "Bearer", "expires_in": 3600, "scope": scopes])
    }

    private func identity(access: String) throws -> String {
        var header: [String: Any] = ["alg": "ES256", "kid": "test-key"]
        var claims: [String: Any] = ["iss": OpenAIDiscovery.issuer, "aud": issuedClient, "sub": "verified-subject",
                                     "nonce": nonce, "iat": time.now.timeIntervalSince1970,
                                     "exp": time.now.timeIntervalSince1970 + 3600,
                                     "name": "Sable Test", "email": "sable+test@example.test"]
        switch mutation {
        case .nonce: claims["nonce"] = "wrong-nonce"
        case .issuer: claims["iss"] = "https://untrusted.test"
        case .audience: claims["aud"] = "another-client"
        case .expiry: claims["exp"] = time.now.timeIntervalSince1970 - 1
        case .subject: claims["sub"] = "another-subject"
        case .futureIssuedAt: claims["iat"] = time.now.timeIntervalSince1970 + 60
        case .missingSubject: claims.removeValue(forKey: "sub")
        case .algorithm: header["alg"] = "none"
        case .keyID: header["kid"] = "untrusted-key"
        case .accessHash: claims["at_hash"] = "invalid-hash"
        case .multipleAudiences: claims["aud"] = [issuedClient, "other-client"]
        default: break
        }
        let input = try JSONSerialization.data(withJSONObject: header).base64URL + "."
            + JSONSerialization.data(withJSONObject: claims).base64URL
        var signature = try signingKey.signature(for: Data(input.utf8)).rawRepresentation
        if mutation == .signature { signature[0] ^= 1 }
        return input + "." + signature.base64URL
    }

    private func json(_ value: [String: Any], status: Int = 200) throws -> ConnectionHTTPResponse {
        ConnectionHTTPResponse(statusCode: status, data: try JSONSerialization.data(withJSONObject: value))
    }

    private func decodeForm(_ data: Data) -> [String: String] {
        let value = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "+", with: "%20")
        return Dictionary(uniqueKeysWithValues: URLComponents(string: "?" + value)!.queryItems!.map { ($0.name, $0.value!) })
    }
}

// Eager arguments allow actor reads to finish before XCTest's synchronous
// autoclosures, while preserving the originating test location on failure.
private func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs, rhs, message, file: file, line: line)
}
private func assertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(value, file: file, line: line)
}
private func assertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(value, file: file, line: line)
}
private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
