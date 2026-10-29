import XCTest
@testable import SableCore

/// Gates actual catalog HTTP handoffs so settings invalidation can race with a
/// rewrite's discovery without sockets, credentials or wall-clock sleeps.
final class GenerationCatalogInvalidationTests: XCTestCase {
    func testSameAccountRefreshDoesNotFailPendingLoadOrRepublishInvalidatedCache() async throws {
        let first = expectation(description: "old discovery")
        let second = expectation(description: "fresh discovery")
        let http = CatalogHTTP { index in (index == 0 ? first : second).fulfill() }
        let catalog = DirectGenerationModelCatalog(connection: CatalogConnection(), httpClient: http)
        let pending = Task { try await catalog.models(for: .chatGPT) }
        await fulfillment(of: [first], timeout: 2)
        await catalog.invalidate()
        http.complete(0, json: chatGPTModels("old"))
        let oldModels = try await pending.value
        XCTAssertEqual(oldModels.map(\.id), ["old"])
        let fresh = Task { try await catalog.models(for: .chatGPT) }
        await fulfillment(of: [second], timeout: 2)
        http.complete(1, json: chatGPTModels("fresh"))
        let freshModels = try await fresh.value
        XCTAssertEqual(freshModels.map(\.id), ["fresh"])
        XCTAssertEqual(http.count, 2)
    }

    func testOlderSameAccountCompletionCannotOverwriteNewerRefreshedCache() async throws {
        let first = expectation(description: "old discovery")
        let second = expectation(description: "refreshed discovery")
        let http = CatalogHTTP { index in (index == 0 ? first : second).fulfill() }
        let catalog = DirectGenerationModelCatalog(connection: CatalogConnection(), httpClient: http)
        let old = Task { try await catalog.models(for: .chatGPT) }
        await fulfillment(of: [first], timeout: 2)
        await catalog.invalidate(provider: .chatGPT)
        let fresh = Task { try await catalog.models(for: .chatGPT) }
        await fulfillment(of: [second], timeout: 2)
        http.complete(1, json: chatGPTModels("fresh"))
        _ = try await fresh.value
        http.complete(0, json: chatGPTModels("old"))
        _ = try await old.value
        let cached = try await catalog.models(for: .chatGPT)
        XCTAssertEqual(cached.map(\.id), ["fresh"])
        XCTAssertEqual(http.count, 2)
    }

    func testRealAccountChangeStillRejectsPendingLoad() async throws {
        let started = expectation(description: "discovery")
        let http = CatalogHTTP { _ in started.fulfill() }
        let connection = CatalogConnection()
        let catalog = DirectGenerationModelCatalog(connection: connection, httpClient: http)
        let pending = Task { try await catalog.models(for: .chatGPT) }
        await fulfillment(of: [started], timeout: 2)
        await catalog.invalidate(provider: .chatGPT)
        await connection.select("another-account")
        http.complete(0, json: chatGPTModels("old-account-model"))
        do { _ = try await pending.value; XCTFail("changed account must reject old discovery") }
        catch { XCTAssertEqual(error as? GenerationError, .accountChanged) }
    }

    func testRealSignOutStillRejectsPendingLoad() async throws {
        let started = expectation(description: "discovery")
        let http = CatalogHTTP { _ in started.fulfill() }
        let connection = CatalogConnection()
        let catalog = DirectGenerationModelCatalog(connection: connection, httpClient: http)
        let pending = Task { try await catalog.models(for: .chatGPT) }
        await fulfillment(of: [started], timeout: 2)
        await connection.select(nil)
        await catalog.invalidate(provider: .chatGPT)
        http.complete(0, json: chatGPTModels("old-model"))
        do { _ = try await pending.value; XCTFail("signed-out connection must reject old discovery") }
        catch { XCTAssertEqual(error as? ConnectionError, .notConnected) }
    }

    func testOpenRouterChangesPreserveChatGPTPendingLoadAndCache() async throws {
        let started = expectation(description: "ChatGPT discovery")
        let http = CatalogHTTP { _ in started.fulfill() }
        let catalog = DirectGenerationModelCatalog(connection: CatalogConnection(), httpClient: http)
        let pending = Task { try await catalog.models(for: .chatGPT) }
        await fulfillment(of: [started], timeout: 2)
        await catalog.invalidate(provider: .openRouter)
        http.complete(0, json: chatGPTModels("chatgpt"))
        _ = try await pending.value
        await catalog.invalidate(provider: .openRouter)
        let cached = try await catalog.models(for: .chatGPT)
        XCTAssertEqual(cached.map(\.id), ["chatgpt"])
        XCTAssertEqual(http.count, 1)
    }

    func testOpenRouterOldCompletionCannotRepublishCacheOrReasoningCapabilities() async throws {
        let first = expectation(description: "old OpenRouter discovery")
        let second = expectation(description: "fresh OpenRouter discovery")
        let http = CatalogHTTP { index in (index == 0 ? first : second).fulfill() }
        let catalog = DirectGenerationModelCatalog(keyStore: CatalogKeys(), httpClient: http)
        let old = Task { try await catalog.models(for: .openRouter) }
        await fulfillment(of: [first], timeout: 2)
        await catalog.invalidate(provider: .openRouter)
        let fresh = Task { try await catalog.models(for: .openRouter) }
        await fulfillment(of: [second], timeout: 2)
        http.complete(1, json: openRouterModels("fresh", allowsNone: false))
        _ = try await fresh.value
        http.complete(0, json: openRouterModels("old", allowsNone: true))
        _ = try await old.value
        let cached = try await catalog.models(for: .openRouter)
        let oldCapability = await catalog.canDisableReasoning(model: "old")
        XCTAssertEqual(cached.map(\.id), ["fresh"])
        XCTAssertFalse(oldCapability)
        XCTAssertEqual(http.count, 2)
    }

    private func chatGPTModels(_ id: String) -> String {
        "{\"models\":[{\"slug\":\"\(id)\",\"display_name\":\"Fixture\",\"visibility\":\"list\"}]}"
    }

    private func openRouterModels(_ id: String, allowsNone: Bool) -> String {
        "{\"data\":[{\"id\":\"\(id)\",\"name\":\"Fixture\",\"architecture\":{\"input_modalities\":[\"text\"],\"output_modalities\":[\"text\"]},\"supported_parameters\":[\"reasoning\"],\"reasoning\":{\"mandatory\":false,\"supported_efforts\":[\"\(allowsNone ? "none" : "high")\"]}}]}"
    }
}

private actor CatalogConnection: ChatGPTConnecting {
    private var account: String? = "fixture-account"
    func select(_ account: String?) { self.account = account }
    func status() -> ConnectionStatus { ConnectionStatus() }
    func accessToken() throws -> ConnectionAccessToken {
        guard let account else { throw ConnectionError.notConnected }
        return ConnectionAccessToken(secret: ConnectionSecret("fixture"), expiresAt: .distantFuture, accountID: account)
    }
    func signIn(openBrowser: @escaping ConnectionBrowserOpener) throws -> ConnectionAccount { throw ConnectionError.notImplemented }
    func cancelSignIn() {}
    func disconnect() { account = nil }
}

private actor CatalogKeys: OpenRouterKeyStore {
    func hasKey() -> Bool { true }
    func loadKey() -> ConnectionSecret? { ConnectionSecret("fixture-key") }
    func saveKey(_ key: ConnectionSecret) {}
    func removeKey() {}
}

/// Stream creation and test completion can run on different executors. Only the
/// continuation registry is locked; yielding and XCTest callbacks run outside it.
private final class CatalogHTTP: GenerationHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AsyncThrowingStream<GenerationHTTPEvent, Error>.Continuation] = []
    private let started: @Sendable (Int) -> Void
    init(started: @escaping @Sendable (Int) -> Void) { self.started = started }
    var count: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    func events(for request: URLRequest) -> AsyncThrowingStream<GenerationHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            let index = pending.count
            pending.append(continuation)
            lock.unlock()
            started(index)
        }
    }
    func complete(_ index: Int, json: String) {
        lock.lock()
        let continuation = pending[index]
        lock.unlock()
        continuation.yield(.response(status: 200, contentType: "application/json", requestID: "fixture"))
        continuation.yield(.data(Data(json.utf8)))
        continuation.finish()
    }
}
