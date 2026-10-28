import XCTest
@testable import SableCore

final class DirectGenerationTests: XCTestCase {
    func testChatGPTRequestUsesAccountCatalogAndOnlyText() async throws {
        let connection = GenerationTestConnection()
        let http = ScriptedGenerationHTTP([
            .json(chatGPTCatalog), .sse(chatGPTSuccess), .sse(chatGPTSuccess)
        ])
        let catalog = DirectGenerationModelCatalog(connection: connection, httpClient: http)
        let adapter = ChatGPTGenerationAdapter(connection: connection, catalog: catalog, httpClient: http)
        var request = rewriteRequest()
        request.cli = CLIGenerationContext(runtimeID: .claude, cwd: URL(fileURLWithPath: "/unread"), model: "sonnet", screenshotPath: "/unread.png")
        let first = try await adapter.rewrite(request)
        let second = try await adapter.rewrite(request)
        XCTAssertEqual(first, "Hello 👩🏽‍💻 café\n")
        XCTAssertEqual(second, first)
        let requests = http.requests
        XCTAssertEqual(requests.map { $0.url!.absoluteString }, [
            "https://api.openai.com/v1/models", "https://api.openai.com/v1/responses", "https://api.openai.com/v1/responses"
        ])
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "account-first")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, request.instruction)
        XCTAssertEqual((body["input"] as? [[String: String]])?.first?["content"], request.selectedText)
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["screenshot"])
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
    }

    func testResponsesAcceptsOnlyCompletedTerminalAndNoPartialOutput() async throws {
        let partial = sse(["type": "response.output_text.delta", "delta": "partial"])
        let cases: [(String, GenerationError)] = [
            (partial, .interrupted),
            (partial + sse(["type": "response.output_text.done", "text": "partial"]), .interrupted),
            (partial + sse(["type": "response.incomplete", "response": ["status": "incomplete"]]), .incomplete),
            (partial + "data: {broken}\n\n", .invalidResponse),
            (partial + "event: wrong\ndata: {\"type\":\"response.completed\"}\n\n", .invalidResponse),
            (partial + sse(["type": "response.refusal.delta", "delta": "refuse"]), .refused),
            (partial + sse(["type": "response.completed", "response": ["status": "incomplete"]]), .invalidResponse),
            (partial + sse(["type": "response.completed", "response": ["status": "completed", "output": [["content": [["type": "refusal", "refusal": "No"]]]]]]), .refused),
            (completedEvent(), .emptyOutput),
            ("data: [DONE]\n\n", .interrupted),
            (partial + completedEvent().trimmingCharacters(in: .newlines), .interrupted)
        ]
        for (body, expected) in cases {
            let adapter = testChatGPT(http: ScriptedGenerationHTTP([.sse(body)]))
            await expectError(expected) { try await adapter.rewrite(self.rewriteRequest()) }
        }
    }

    func testLateUsageFailurePreservesCodeAndNeverReturnsPartial() async throws {
        for code in ["subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable"] {
            let body = sse(["type": "response.output_text.delta", "delta": "partial"]) + sse([
                "type": "response.failed", "response": ["error": ["code": code, "message": "fixture-secret"]]
            ])
            do {
                _ = try await testChatGPT(http: ScriptedGenerationHTTP([.sse(body)])).rewrite(rewriteRequest())
                XCTFail("Expected late usage error")
            } catch GenerationError.providerFailure(let failure) {
                XCTAssertEqual(failure.code, code)
                XCTAssertEqual(failure.requestID, "req_fixture")
                XCTAssertFalse(failure.localizedDescription.contains("fixture-secret"))
                XCTAssertFalse(String(reflecting: failure).contains("fixture-secret"))
            }
        }
    }

    func testResponsesTopLevelErrorAbortsNamedAndUnnamedStreams() async throws {
        let payload: [String: Any] = ["type": "error", "code": "subscription_sharing_usage_limit_exceeded", "param": "model", "message": "fixture-secret"]
        let partial = sse(["type": "response.output_text.delta", "delta": "partial"])
        for prefix in ["", "event: error\n"] {
            let body = partial + prefix + sse(payload) + completedEvent()
            do {
                _ = try await testChatGPT(http: ScriptedGenerationHTTP([.sse(body)])).rewrite(rewriteRequest())
                XCTFail("Expected explicit Responses error")
            } catch GenerationError.providerFailure(let failure) {
                XCTAssertEqual(failure.code, "subscription_sharing_usage_limit_exceeded")
                XCTAssertEqual(failure.parameter, "model")
                XCTAssertFalse(failure.localizedDescription.contains("fixture-secret"))
            }
        }
    }

    func testEmptyOrMismatchedTerminalOutputCannotDeliverPartialText() async {
        let partial = sse(["type": "response.output_text.delta", "delta": "partial"])
        let terminal = sse(["type": "response.completed", "response": ["status": "completed", "output": []]])
        await expectError(.emptyOutput) {
            try await self.testChatGPT(http: ScriptedGenerationHTTP([.sse(partial + terminal)])).rewrite(self.rewriteRequest())
        }
        await expectError(.invalidResponse) {
            try await self.testChatGPT(http: ScriptedGenerationHTTP([.sse(partial + completedEvent(text: "different"))])).rewrite(self.rewriteRequest())
        }
    }

    func testDiagnosticsKeepUnknownMachineFieldsAndRedactActiveCredential() async throws {
        for (code, parameter, expectedCode, expectedParameter) in [
            ("subscription_sharing_future_code", "input[0].content[0].type", "subscription_sharing_future_code", "input[0].content[0].type"),
            ("fixture-token", "input.fixture-token", nil, nil)
        ] as [(String, String, String?, String?)] {
            let body = sse(["type": "error", "code": code, "param": parameter, "message": "fixture-token"])
            do {
                _ = try await testChatGPT(http: ScriptedGenerationHTTP([.sse(body)])).rewrite(rewriteRequest())
                XCTFail("Expected provider failure")
            } catch GenerationError.providerFailure(let failure) {
                XCTAssertEqual(failure.code, expectedCode)
                XCTAssertEqual(failure.parameter, expectedParameter)
                XCTAssertEqual(failure.status, 200)
                XCTAssertFalse(String(reflecting: failure).contains("fixture-token"))
            }
        }
    }

    func testExplicitNullReasoningEffortsAcceptAllGatewayEfforts() async throws {
        let entries = #"{"data":[{"id":"fixture/null","name":"Null efforts","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"supported_parameters":["reasoning"],"reasoning":{"mandatory":false,"supported_efforts":null}},{"id":"fixture/missing","name":"Missing efforts","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"supported_parameters":["reasoning"],"reasoning":{"mandatory":false}}]}"#
        let catalog = DirectGenerationModelCatalog(keyStore: GenerationTestKeys(), httpClient: ScriptedGenerationHTTP([.json(entries)]))
        _ = try await catalog.models(for: .openRouter)
        let unrestricted = await catalog.canDisableReasoning(model: "fixture/null")
        let missing = await catalog.canDisableReasoning(model: "fixture/missing")
        XCTAssertTrue(unrestricted)
        XCTAssertFalse(missing)
    }

    func testHTTPAdmissionErrorsAndMalformedSSEAreSanitized() async throws {
        let http = ScriptedGenerationHTTP([.init(status: 401, body: Data(#"{"detail":"Bearer fixture-secret"}"#.utf8))])
        do {
            _ = try await testChatGPT(http: http).rewrite(rewriteRequest())
            XCTFail("Expected admission failure")
        } catch GenerationError.providerFailure(let failure) {
            XCTAssertEqual(failure.status, 401)
            XCTAssertEqual(failure.bodyShape, .detail)
            XCTAssertFalse(failure.localizedDescription.contains("fixture-secret"))
        }
        let error = sse(["error": ["code": "subscription_sharing_unsupported_capability", "param": "tools", "message": "fixture-secret"]])
        do {
            _ = try await testChatGPT(http: ScriptedGenerationHTTP([.sse(error)])).rewrite(rewriteRequest())
            XCTFail("Expected SSE error")
        } catch GenerationError.providerFailure(let failure) {
            XCTAssertEqual(failure.parameter, "tools")
            XCTAssertFalse(failure.localizedDescription.contains("fixture-secret"))
        }
        var invalidUTF8 = Data("data: ".utf8)
        invalidUTF8.append(0xff)
        invalidUTF8.append(Data("\n\n".utf8))
        await expectError(.invalidResponse) {
            try await self.testChatGPT(http: ScriptedGenerationHTTP([.init(body: invalidUTF8)])).rewrite(self.rewriteRequest())
        }
        await expectError(.invalidResponse) {
            try await self.testChatGPT(http: ScriptedGenerationHTTP([.init(contentType: "application/json", body: Data("{}".utf8))])).rewrite(self.rewriteRequest())
        }
    }

    func testSSEByteFramingHandlesMultilineCommentsCRLFAndUnicode() throws {
        var parser = ServerSentEvents()
        let source = "\u{FEFF}: keepalive\r\nevent: response.output_text.delta\r\ndata: {\r\ndata: \"type\":\"response.output_text.delta\",\"delta\":\"é 👩🏽‍💻\"}\r\n\r\n: hi\r\r"
        var events: [ServerSentEvent] = []
        for byte in source.utf8 { events += try parser.append(Data([byte])) }
        XCTAssertEqual(events.count, 1)
        var consumer = GenerationStreamConsumer(provider: .chatGPT)
        XCTAssertNil(try consumer.consume(events[0]))
        let done = try XCTUnwrap(try parser.append(Data(completedEvent(text: "é 👩🏽‍💻").utf8)).first)
        XCTAssertEqual(try consumer.consume(done), "é 👩🏽‍💻")
    }

    func testCatalogFiltersVisibilityPreservesServerOrderAndRefreshesForAccount() async throws {
        let connection = GenerationTestConnection()
        let http = ScriptedGenerationHTTP([.json(chatGPTCatalog), .json(chatGPTCatalog)])
        let catalog = DirectGenerationModelCatalog(connection: connection, httpClient: http)
        let first = try await catalog.models(for: .chatGPT)
        let cached = try await catalog.models(for: .chatGPT)
        XCTAssertEqual(first.map(\.id), ["account-first", "account-second"])
        XCTAssertEqual(first.map(\.displayName), ["First Account Model", "Second Account Model"])
        XCTAssertEqual(cached, first)
        XCTAssertEqual(http.requests.count, 1)
        await connection.changeAccount("replacement")
        _ = try await catalog.models(for: .chatGPT)
        XCTAssertEqual(http.requests.count, 2)
    }

    func testAccountSwitchDuringDiscoveryRejectsStaleCatalog() async throws {
        let connection = GenerationTestConnection()
        var delayed = HTTPPlan.json(chatGPTCatalog)
        delayed.beforeHeadersDelay = 0.03
        let http = ScriptedGenerationHTTP([delayed, .json(chatGPTCatalog)])
        let catalog = DirectGenerationModelCatalog(connection: connection, httpClient: http)
        let pending = Task { try await catalog.models(for: .chatGPT) }
        try await waitUntil { !http.requests.isEmpty }
        await connection.changeAccount("new-account")
        do { _ = try await pending.value; XCTFail("Expected stale account rejection") }
        catch { XCTAssertEqual(error as? GenerationError, .accountChanged) }
        let fresh = try await catalog.models(for: .chatGPT)
        XCTAssertEqual(fresh.map(\.id), ["account-first", "account-second"])
        XCTAssertEqual(http.requests.count, 2)
    }

    func testCatalogRejectsGenericAPIShapeAndEmptyVisibleModels() async {
        for (body, expected) in [(#"{"data":[{"id":"fictitious"}]}"#, GenerationError.invalidResponse), (#"{"models":[{"visibility":"hidden","slug":"hidden"}]}"#, .noModels)] {
            let catalog = DirectGenerationModelCatalog(connection: GenerationTestConnection(), httpClient: ScriptedGenerationHTTP([.json(body)]))
            do { _ = try await catalog.models(for: .chatGPT); XCTFail("Expected invalid or empty account catalog") }
            catch { XCTAssertEqual(error as? GenerationError, expected) }
        }
    }

    func testExplicitDirectModelDoesNotUseLegacyAliasOrFallback() async {
        let http = ScriptedGenerationHTTP([])
        var request = rewriteRequest()
        request.selection.model = "sonnet"
        let adapter = testChatGPT(http: http)
        await expectError(.modelUnavailable) { try await adapter.rewrite(request) }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testOpenRouterRequestDefaultAndExplicitModelAndFullCompletion() async throws {
        let keyStore = GenerationTestKeys()
        let http = ScriptedGenerationHTTP([.json(openRouterCatalog), .sse(openRouterSuccess), .sse(openRouterSuccess)])
        let catalog = DirectGenerationModelCatalog(keyStore: keyStore, httpClient: http)
        let adapter = OpenRouterGenerationAdapter(keyStore: keyStore, catalog: catalog, httpClient: http)
        var request = rewriteRequest(.openRouter)
        let output = try await adapter.rewrite(request)
        XCTAssertEqual(output, "result")
        request.selection.model = "fixture/optional-reasoning"
        _ = try await adapter.rewrite(request)
        let calls = http.requests
        XCTAssertEqual(calls.count, 3)
        let first = try JSONSerialization.jsonObject(with: calls[1].httpBody!) as! [String: Any]
        XCTAssertEqual(first["model"] as? String, "openai/gpt-4.1-mini")
        XCTAssertEqual((first["provider"] as? [String: Any])?["sort"] as? String, "latency")
        XCTAssertEqual((first["provider"] as? [String: Any])?["allow_fallbacks"] as? Bool, false)
        XCTAssertNil(first["reasoning"])
        XCTAssertNil(first["tools"])
        XCTAssertEqual(calls[1].url!.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        let explicit = try JSONSerialization.jsonObject(with: calls[2].httpBody!) as! [String: Any]
        XCTAssertEqual((explicit["reasoning"] as? [String: String])?["effort"], "none")
    }

    func testOpenRouterRejectsMissingDoneLengthAndLateErrors() async throws {
        let partial = sse(["choices": [["index": 0, "delta": ["content": "partial"]]]])
        let cases: [(String, GenerationError)] = [
            (partial, .interrupted),
            (partial + sse(["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]]), .interrupted),
            (partial + sse(["choices": [["index": 0, "delta": [:], "finish_reason": "length"]]]), .incomplete),
            (partial + sse(["choices": [["index": 0, "delta": [:], "finish_reason": "content_filter"]]]), .refused),
            (partial + "data: [DONE]\n\n", .interrupted)
        ]
        for (body, expected) in cases {
            let adapter = OpenRouterGenerationAdapter(keyStore: GenerationTestKeys(), catalog: FixedGenerationCatalog(), httpClient: ScriptedGenerationHTTP([.sse(body)]))
            await expectError(expected) { try await adapter.rewrite(self.rewriteRequest(.openRouter)) }
        }
        let late = partial + sse(["error": ["code": 429, "message": "fixture-secret"], "choices": [["finish_reason": "error"]]])
        let adapter = OpenRouterGenerationAdapter(keyStore: GenerationTestKeys(), catalog: FixedGenerationCatalog(), httpClient: ScriptedGenerationHTTP([.sse(late)]))
        do {
            _ = try await adapter.rewrite(rewriteRequest(.openRouter))
            XCTFail("Expected late stream error")
        } catch GenerationError.providerFailure(let failure) {
            XCTAssertEqual(failure.status, 200)
            XCTAssertEqual(failure.code, "429")
        }
    }

    func testMissingOpenRouterKeyStartsNoHTTP() async {
        let http = ScriptedGenerationHTTP([])
        let adapter = OpenRouterGenerationAdapter(keyStore: GenerationTestKeys(key: nil), httpClient: http)
        await expectError(.missingOpenRouterKey) { try await adapter.rewrite(self.rewriteRequest(.openRouter)) }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testCancellationBeforeHeadersAndBetweenEvents() async throws {
        for beforeHeaders in [true, false] {
            let http = ScriptedGenerationHTTP([.init(beforeHeadersDelay: beforeHeaders ? 60 : 0, stallAfterBody: true)])
            let adapter = testChatGPT(http: http)
            let task = Task { try await adapter.rewrite(self.rewriteRequest()) }
            try await waitUntil { !http.requests.isEmpty }
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            try await waitUntil { http.terminated == 1 }
        }
    }

    func testDeadlineBoundsDiscoveryHeadersAndEndlessHeartbeats() async throws {
        for plan in [HTTPPlan(beforeHeadersDelay: 60), HTTPPlan(heartbeat: true)] {
            let http = ScriptedGenerationHTTP([plan])
            var request = rewriteRequest()
            request.timeoutSeconds = 0.06
            let start = ContinuousClock.now
            await expectError(.deadlineExceeded) { try await self.testChatGPT(http: http).rewrite(request) }
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
            try await waitUntil { http.terminated == 1 }
        }
        let http = ScriptedGenerationHTTP([.init(beforeHeadersDelay: 60)])
        let connection = GenerationTestConnection()
        let catalog = DirectGenerationModelCatalog(connection: connection, httpClient: http)
        let adapter = ChatGPTGenerationAdapter(connection: connection, catalog: catalog, httpClient: http)
        var request = rewriteRequest()
        request.timeoutSeconds = 0.06
        await expectError(.deadlineExceeded) { try await adapter.rewrite(request) }
    }

    func testWholeOperationDeadlineAndPreCancellationValidateInput() async {
        for timeout in [0, -1, .infinity, .nan] {
            var request = rewriteRequest()
            request.timeoutSeconds = timeout
            await expectError(.deadlineExceeded) { try await self.testChatGPT(http: ScriptedGenerationHTTP([])).rewrite(request) }
        }
    }

    private func testChatGPT(http: any GenerationHTTPClient) -> ChatGPTGenerationAdapter {
        ChatGPTGenerationAdapter(connection: GenerationTestConnection(), catalog: FixedGenerationCatalog(), httpClient: http)
    }

    private func rewriteRequest(_ provider: GenerationProvider = .chatGPT) -> GenerationRequest {
        GenerationRequest(selection: GenerationSelection(provider: provider), instruction: "Preserve my custom instruction exactly.", selectedText: "Original 👋")
    }
}

// All credentials below are fixed test strings; every HTTP exchange is injected.
private actor GenerationTestConnection: ChatGPTConnecting {
    private var accountID = "fixture-account"
    func changeAccount(_ id: String) { accountID = id }
    func status() -> ConnectionStatus { ConnectionStatus(activeAccount: ConnectionAccount(id: accountID, displayName: "Fixture")) }
    func accessToken() -> ConnectionAccessToken { ConnectionAccessToken(secret: ConnectionSecret("fixture-token"), expiresAt: .distantFuture, accountID: accountID) }
    func signIn(openBrowser: @escaping ConnectionBrowserOpener) throws -> ConnectionAccount { throw ConnectionError.notImplemented }
    func cancelSignIn() {}
    func disconnect() throws { throw ConnectionError.notImplemented }
}

private actor GenerationTestKeys: OpenRouterKeyStore {
    var key: ConnectionSecret?
    init(key: String? = "fixture-key") { self.key = key.map(ConnectionSecret.init) }
    func hasKey() -> Bool { key != nil }
    func loadKey() -> ConnectionSecret? { key }
    func saveKey(_ key: ConnectionSecret) { self.key = key }
    func removeKey() { key = nil }
}

private struct FixedGenerationCatalog: GenerationModelCatalog {
    func models(for provider: GenerationProvider) async throws -> [GenerationModel] {
        [GenerationModel(id: "account-first", displayName: "Fixture"), GenerationModel(id: "openai/gpt-4.1-mini", displayName: "Fixture")]
    }
}

private struct HTTPPlan: Sendable {
    var status = 200
    var contentType = "text/event-stream"
    var body = Data()
    var beforeHeadersDelay: TimeInterval = 0
    var stallAfterBody = false
    var heartbeat = false
    static func json(_ value: String) -> Self { Self(contentType: "application/json", body: Data(value.utf8)) }
    static func sse(_ value: String) -> Self { Self(body: Data(value.utf8)) }
}

/// This fixture models async header/body handoffs and cooperative teardown,
/// rather than starting a fake CLI or making authenticated network requests.
private final class ScriptedGenerationHTTP: GenerationHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [HTTPPlan]
    private var recorded: [URLRequest] = []
    private var terminations = 0
    init(_ plans: [HTTPPlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    var terminated: Int { lock.lock(); defer { lock.unlock() }; return terminations }
    private func terminate() { lock.lock(); terminations += 1; lock.unlock() }

    func events(for request: URLRequest) -> AsyncThrowingStream<GenerationHTTPEvent, Error> {
        lock.lock()
        recorded.append(request)
        let plan = plans.isEmpty ? nil : plans.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            guard let plan else { continuation.finish(throwing: GenerationError.invalidResponse); return }
            let task = Task {
                do {
                    if plan.beforeHeadersDelay > 0 { try await Task.sleep(for: .seconds(plan.beforeHeadersDelay)) }
                    continuation.yield(.response(status: plan.status, contentType: plan.contentType, requestID: "req_fixture"))
                    if !plan.body.isEmpty { continuation.yield(.data(plan.body)) }
                    if plan.heartbeat {
                        while true {
                            try await Task.sleep(for: .milliseconds(10))
                            continuation.yield(.data(Data(": heartbeat\n\n".utf8)))
                        }
                    }
                    if plan.stallAfterBody { try await Task.sleep(for: .seconds(60)) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel(); self.terminate() }
        }
    }
}

private func expectError(_ expected: GenerationError, operation: () async throws -> String, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? GenerationError, expected, file: file, line: line) }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for test transport")
}

private func sse(_ payload: [String: Any]) -> String {
    "data: " + String(data: try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8)! + "\n\n"
}
private func completedEvent(text: String = "") -> String {
    sse(["type": "response.completed", "response": ["status": "completed", "output": [["type": "message", "status": "completed", "content": [["type": "output_text", "text": text]]]]]])
}
private let chatGPTCatalog = #"{"models":[{"visibility":"hidden","slug":"hidden","display_name":"Hidden"},{"visibility":"list","slug":"account-first","display_name":"First Account Model"},{"visibility":"list","slug":"account-second","display_name":"Second Account Model"}]}"#
private let chatGPTSuccess = sse(["type": "response.output_text.delta", "delta": "Hello 👩🏽‍💻 café\n"]) + completedEvent(text: "Hello 👩🏽‍💻 café\n")
private let openRouterCatalog = #"{"data":[{"id":"image-only","name":"Image","architecture":{"input_modalities":["text"],"output_modalities":["image"]}},{"id":"openai/gpt-4.1-mini","name":"GPT-4.1 Mini","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"supported_parameters":["temperature"]},{"id":"fixture/optional-reasoning","name":"Optional","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"supported_parameters":["reasoning"],"reasoning":{"mandatory":false,"supported_efforts":["none","low"]}}]}"#
private let openRouterSuccess = sse(["choices": [["index": 0, "delta": ["content": "result"]]]]) + sse(["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]]) + sse(["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]], "usage": ["total_tokens": 2]]) + "data: [DONE]\n\n"
