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

    func testResponsesWithoutContentTypeStillRequiresValidatedCompletedSSE() async throws {
        // The live ChatGPT endpoint can omit Content-Type on HTTP 200. Exercise
        // the adapter boundary so missing metadata cannot bypass SSE validation.
        let http = ScriptedGenerationHTTP([.init(contentType: nil, body: Data(chatGPTSuccess.utf8))])
        let output = try await testChatGPT(http: http).rewrite(rewriteRequest())
        XCTAssertEqual(output, "Hello 👩🏽‍💻 café\n")

        let partial = sse(["type": "response.output_text.delta", "delta": "partial"])
        let cases: [(String, GenerationError)] = [
            (partial, .interrupted),
            ("data: {broken}\n\n", .invalidResponse),
            ("{\"output_text\":\"unframed\"}", .interrupted),
            (partial + completedEvent(text: "different"), .invalidResponse),
            (partial + sse(["type": "response.incomplete"]), .incomplete),
            (partial + sse(["type": "response.refusal.delta", "delta": "refused"]), .refused),
            (completedEvent(), .emptyOutput),
            ("data: [DONE]\n\n", .interrupted),
            (completedEvent(text: "complete").trimmingCharacters(in: .newlines), .interrupted),
            ("event: wrong\n" + completedEvent(text: "complete"), .invalidResponse)
        ]
        for (body, expected) in cases {
            await expectError(expected) {
                try await self.testChatGPT(http: ScriptedGenerationHTTP([
                    .init(contentType: nil, body: Data(body.utf8))
                ])).rewrite(self.rewriteRequest())
            }
        }
    }

    func testResponsesExplicitWrongContentTypesStillRejectValidSSE() async {
        for contentType in ["application/json", "text/html", "text/plain", ""] {
            await expectError(.invalidResponse) {
                try await self.testChatGPT(http: ScriptedGenerationHTTP([
                    .init(contentType: contentType, body: Data(chatGPTSuccess.utf8))
                ])).rewrite(self.rewriteRequest())
            }
        }
    }

    func testOpenRouterStillRequiresEventStreamContentType() async {
        let adapter = OpenRouterGenerationAdapter(
            keyStore: GenerationTestKeys(), catalog: FixedGenerationCatalog(),
            httpClient: ScriptedGenerationHTTP([.init(contentType: nil, body: Data(openRouterSuccess.utf8))])
        )
        await expectError(.invalidResponse) { try await adapter.rewrite(self.rewriteRequest(.openRouter)) }
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

    func testMetadataOnlyTerminalDeliversOnlyCorrelatedCompletedMessage() async throws {
        // Synthetic shape of the live Terra failure: every text/item done event
        // contains the answer, but the successful response fence has output=[].
        for contentType in [nil, "text/event-stream"] as [String?] {
            let events = correlatedResponseEvents()
            let http = ScriptedGenerationHTTP([.init(contentType: contentType, body: Data(events.map(sse).joined().utf8))])
            var request = rewriteRequest()
            request.selection.model = "gpt-6.1-terra"
            let output = try await testChatGPT(http: http).rewrite(request)
            XCTAssertEqual(output, "Corrected 👩🏽‍💻 café\n")
            XCTAssertEqual(http.requests.count, 1)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: http.requests[0].httpBody!) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "gpt-6.1-terra")
            XCTAssertNil(body["reasoning"])
            XCTAssertNil(body["tools"])
        }
    }

    func testCompletedItemNeverPublishesBeforeResponseFence() throws {
        var consumer = GenerationStreamConsumer(provider: .chatGPT)
        let events = correlatedResponseEvents()
        for event in events.dropLast() {
            XCTAssertNil(try consumer.consume(ServerSentEvent(name: nil, data: json(event))))
        }
        XCTAssertEqual(try consumer.consume(ServerSentEvent(name: "response.completed", data: json(events.last!))), "Corrected 👩🏽‍💻 café\n")
    }

    func testCompletedItemsAgreeWithNonemptyTerminalAndIgnoreReasoningContent() async throws {
        for metadataOnly in [true, false] {
            var events = correlatedResponseEvents()
            // Reasoning may own output index zero. It cannot become replacement
            // text even when its content events contain a text-shaped field.
            for index in events.indices where events[index]["output_index"] != nil { events[index]["output_index"] = 1 }
            let reasoning: [String: Any] = ["id": "reason_fixture", "type": "reasoning", "status": "completed"]
            events.insert(contentsOf: [
                ["type": "response.output_item.added", "output_index": 0, "item": reasoning],
                ["type": "response.content_part.added", "output_index": 0, "item_id": "reason_fixture", "content_index": 0, "part": ["type": "reasoning_text", "text": ""]],
                ["type": "response.content_part.done", "output_index": 0, "item_id": "reason_fixture", "content_index": 0, "part": ["type": "reasoning_text", "text": "private fixture reasoning"]],
                ["type": "response.output_item.done", "output_index": 0, "item": reasoning]
            ], at: 1)
            if !metadataOnly {
                var response = events.last!["response"] as! [String: Any]
                response["output"] = [reasoning, events[events.count - 2]["item"] as! [String: Any]]
                events[events.count - 1]["response"] = response
            }
            let output = try await testChatGPT(http: ScriptedGenerationHTTP([.sse(events.map(sse).joined())])).rewrite(rewriteRequest())
            XCTAssertEqual(output, "Corrected 👩🏽‍💻 café\n")
        }
    }

    func testMetadataOnlyTerminalRejectsDuplicateDoneAndChangedCompletedContent() async {
        for type in ["response.output_text.done", "response.content_part.done", "response.output_item.done"] {
            var events = correlatedResponseEvents()
            let index = events.firstIndex { $0["type"] as? String == type }!
            events.insert(events[index], at: index + 1)
            await expectError(.invalidResponse) {
                try await self.testChatGPT(http: ScriptedGenerationHTTP([.sse(events.map(sse).joined())])).rewrite(self.rewriteRequest())
            }
        }
        for type in ["response.content_part.done", "response.output_item.done"] {
            var events = correlatedResponseEvents()
            let index = events.firstIndex { $0["type"] as? String == type }!
            if type == "response.content_part.done" {
                events[index]["part"] = ["type": "output_text", "text": "different"]
            } else {
                var item = events[index]["item"] as! [String: Any]
                item["content"] = [["type": "output_text", "text": "different"]]
                events[index]["item"] = item
            }
            await expectError(.invalidResponse) {
                try await self.testChatGPT(http: ScriptedGenerationHTTP([.sse(events.map(sse).joined())])).rewrite(self.rewriteRequest())
            }
        }
    }

    func testCompletedMessageStillHonorsDeadlineAndCancellationBeforeFence() async throws {
        let body = correlatedResponseEvents().dropLast().map(sse).joined()
        for cancel in [true, false] {
            let http = ScriptedGenerationHTTP([.init(body: Data(body.utf8), stallAfterBody: true)])
            var request = rewriteRequest()
            request.timeoutSeconds = cancel ? 60 : 0.06
            let task = Task { try await self.testChatGPT(http: http).rewrite(request) }
            try await waitUntil { !http.requests.isEmpty }
            if cancel { task.cancel() }
            do { _ = try await task.value; XCTFail("Expected cancellation or deadline") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? GenerationError, .deadlineExceeded) }
            }
            try await waitUntil { http.terminated == 1 }
        }
    }

    func testMetadataOnlyTerminalRejectsMissingCompletionEvidence() async {
        for missing in ["response.created", "response.output_item.added", "response.content_part.added",
                        "response.output_text.delta", "response.output_text.done", "response.content_part.done", "response.output_item.done"] {
            let events = correlatedResponseEvents().filter { $0["type"] as? String != missing }
            await expectError(.invalidResponse) {
                try await self.testChatGPT(http: ScriptedGenerationHTTP([.sse(events.map(sse).joined())])).rewrite(self.rewriteRequest())
            }
        }
        let events = correlatedResponseEvents().dropLast()
        await expectError(.interrupted) {
            try await self.testChatGPT(http: ScriptedGenerationHTTP([.sse(events.map(sse).joined())])).rewrite(self.rewriteRequest())
        }
    }

    func testMetadataOnlyTerminalRejectsCorruptIdentityAndText() async {
        let mutations: [(String, String, Any)] = [
            ("response.output_text.delta", "item_id", "unrelated"),
            ("response.output_text.done", "item_id", "unrelated"),
            ("response.content_part.done", "item_id", "unrelated"),
            ("response.output_text.done", "output_index", 1),
            ("response.content_part.done", "content_index", 1),
            ("response.output_item.done", "output_index", -1),
            ("response.output_text.done", "text", "different"),
            ("response.output_text.delta", "delta", "different")
        ]
        for (type, key, value) in mutations {
            var events = correlatedResponseEvents()
            let index = events.firstIndex { $0["type"] as? String == type }!
            events[index][key] = value
            await expectError(.invalidResponse) {
                try await self.testChatGPT(http: ScriptedGenerationHTTP([.sse(events.map(sse).joined())])).rewrite(self.rewriteRequest())
            }
        }
        for target in ["response.created", "response.completed"] {
            var events = correlatedResponseEvents()
            let index = events.firstIndex { $0["type"] as? String == target }!
            var response = events[index]["response"] as! [String: Any]
            response["id"] = "unrelated-response"
            events[index]["response"] = response
            await expectError(.invalidResponse) {
                try await self.testChatGPT(http: ScriptedGenerationHTTP([.sse(events.map(sse).joined())])).rewrite(self.rewriteRequest())
            }
        }
    }

    func testCompletedItemCannotBypassFailureOrAuthoritativeTerminal() async {
        let partial = Array(correlatedResponseEvents().dropLast())
        let endings: [([String: Any], GenerationError)] = [
            (["type": "response.incomplete"], .incomplete),
            (["type": "response.refusal.done", "refusal": "fixture refusal"], .refused),
            (["type": "response.completed", "response": ["id": "resp_fixture", "status": "in_progress", "output": []]], .invalidResponse),
            (["type": "response.completed", "response": ["id": "resp_fixture", "status": "completed"]], .invalidResponse),
            (["type": "response.completed", "response": ["id": "resp_fixture", "status": "completed", "output": NSNull()]], .invalidResponse),
            (["type": "response.completed", "response": ["id": "resp_fixture", "status": "completed", "output": [], "incomplete_details": ["reason": "max_output_tokens"]]], .incomplete),
            (["type": "response.completed", "response": ["id": "resp_fixture", "status": "completed", "output": [["type": "message", "status": "completed", "content": [["type": "output_text", "text": "different"]]]]]], .invalidResponse)
        ]
        for (ending, error) in endings {
            await expectError(error) {
                try await self.testChatGPT(http: ScriptedGenerationHTTP([.sse((partial + [ending]).map(sse).joined())])).rewrite(self.rewriteRequest())
            }
        }
        for type in ["error", "response.failed"] {
            let error: [String: Any] = ["code": "subscription_sharing_usage_limit_exceeded", "message": "fixture-secret"]
            let ending: [String: Any] = type == "error" ? ["type": type, "error": error] : ["type": type, "response": ["error": error]]
            do {
                _ = try await testChatGPT(http: ScriptedGenerationHTTP([.sse((partial + [ending]).map(sse).joined())])).rewrite(rewriteRequest())
                XCTFail("Expected provider failure")
            } catch GenerationError.providerFailure(let failure) {
                XCTAssertEqual(failure.code, "subscription_sharing_usage_limit_exceeded")
            } catch { XCTFail("Unexpected failure: \(error)") }
        }
    }

    func testMetadataOnlyTerminalRejectsNonAnswerItemsAndIncompleteMessages() async {
        for (field, value, expected) in [
            ("id", "unrelated", GenerationError.invalidResponse),
            ("status", "in_progress", .incomplete),
            ("type", "function_call", .invalidResponse),
            ("role", "user", .invalidResponse),
            ("phase", "commentary", .invalidResponse),
            ("channel", "analysis", .invalidResponse)
        ] {
            var events = correlatedResponseEvents()
            let index = events.firstIndex { $0["type"] as? String == "response.output_item.done" }!
            var item = events[index]["item"] as! [String: Any]
            item[field] = value
            events[index]["item"] = item
            await expectError(expected) {
                try await self.testChatGPT(http: ScriptedGenerationHTTP([.sse(events.map(sse).joined())])).rewrite(self.rewriteRequest())
            }
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
        [GenerationModel(id: "account-first", displayName: "Fixture"), GenerationModel(id: "openai/gpt-4.1-mini", displayName: "Fixture"), GenerationModel(id: "gpt-6.1-terra", displayName: "Fixture Terra")]
    }
}

private struct HTTPPlan: Sendable {
    var status = 200
    var contentType: String? = "text/event-stream"
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
    "data: " + json(payload) + "\n\n"
}
private func json(_ payload: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8)!
}

/// Authored from public event schemas and live structural counts; no captured
/// provider body, user selection, instructions or credential enters this fixture.
private func correlatedResponseEvents(text: String = "Corrected 👩🏽‍💻 café\n") -> [[String: Any]] {
    let part: [String: Any] = ["type": "output_text", "text": text]
    let item: [String: Any] = ["id": "msg_fixture", "type": "message", "role": "assistant", "phase": "final_answer", "status": "completed", "content": [part]]
    var added = item
    added["status"] = "in_progress"
    added["content"] = []
    return [
        ["type": "response.created", "response": ["id": "resp_fixture", "status": "in_progress"]],
        ["type": "response.output_item.added", "output_index": 0, "item": added],
        ["type": "response.content_part.added", "output_index": 0, "item_id": "msg_fixture", "content_index": 0, "part": ["type": "output_text", "text": ""]],
        ["type": "response.output_text.delta", "output_index": 0, "item_id": "msg_fixture", "content_index": 0, "delta": text],
        ["type": "response.output_text.done", "output_index": 0, "item_id": "msg_fixture", "content_index": 0, "text": text],
        ["type": "response.content_part.done", "output_index": 0, "item_id": "msg_fixture", "content_index": 0, "part": part],
        ["type": "response.output_item.done", "output_index": 0, "item": item],
        ["type": "response.completed", "response": ["id": "resp_fixture", "status": "completed", "output": [], "error": NSNull(), "incomplete_details": NSNull()]]
    ]
}
private func completedEvent(text: String = "") -> String {
    sse(["type": "response.completed", "response": ["status": "completed", "output": [["type": "message", "status": "completed", "content": [["type": "output_text", "text": text]]]]]])
}
private let chatGPTCatalog = #"{"models":[{"visibility":"hidden","slug":"hidden","display_name":"Hidden"},{"visibility":"list","slug":"account-first","display_name":"First Account Model"},{"visibility":"list","slug":"account-second","display_name":"Second Account Model"}]}"#
private let chatGPTSuccess = sse(["type": "response.output_text.delta", "delta": "Hello 👩🏽‍💻 café\n"]) + completedEvent(text: "Hello 👩🏽‍💻 café\n")
private let openRouterCatalog = #"{"data":[{"id":"image-only","name":"Image","architecture":{"input_modalities":["text"],"output_modalities":["image"]}},{"id":"openai/gpt-4.1-mini","name":"GPT-4.1 Mini","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"supported_parameters":["temperature"]},{"id":"fixture/optional-reasoning","name":"Optional","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"supported_parameters":["reasoning"],"reasoning":{"mandatory":false,"supported_efforts":["none","low"]}}]}"#
private let openRouterSuccess = sse(["choices": [["index": 0, "delta": ["content": "result"]]]]) + sse(["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]]) + sse(["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]], "usage": ["total_tokens": 2]]) + "data: [DONE]\n\n"
