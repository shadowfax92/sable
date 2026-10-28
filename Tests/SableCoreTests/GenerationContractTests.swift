import XCTest
@testable import SableCore

final class GenerationContractTests: XCTestCase {
    func testLegacyJSONRetainsModeIdentityAndCLISettings() throws {
        let id = UUID()
        let json = """
        {"modes":[{"id":"\(id)","name":"Custom","symbol":"globe",
        "instruction":"Keep my instructions","runtimeID":"codex","model":"legacy-custom",
        "requiresInput":true}],"runtimePaths":{"claudePath":"/custom/claude","codexPath":"/custom/codex"},
        "cwd":"~/work","timeoutSeconds":77,"defaultModeID":"\(id)"}
        """
        let settings = try JSONDecoder().decode(SableSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.generation, GenerationSelection(provider: .legacyCLI))
        XCTAssertNil(settings.modes[0].generation)
        XCTAssertEqual(settings.modes[0].id, id)
        XCTAssertEqual(settings.modes[0].instruction, "Keep my instructions")
        XCTAssertEqual(settings.modes[0].runtimeID, .codex)
        XCTAssertEqual(settings.modes[0].model, "legacy-custom")
        XCTAssertEqual(settings.defaultModeID, id)
        XCTAssertEqual(settings.runtimePaths.codexPath, "/custom/codex")
        XCTAssertEqual(settings.timeoutSeconds, 77)
        XCTAssertEqual(settings.cwd, "~/work")
        XCTAssertTrue(settings.modes[0].requiresInput)
        XCTAssertEqual(try roundTrip(settings), settings)
    }

    func testDirectInheritanceKeepsLegacyModelSeparateAndAllowsExplicitCLIOverride() throws {
        let inherited = SableMode(name: "Custom", instruction: "Rewrite", model: "sonnet")
        let advanced = SableMode(
            name: "Advanced", instruction: "Use CLI", runtimeID: .codex, model: "legacy-model",
            generation: GenerationSelection(provider: .legacyCLI)
        )
        let settings = SableSettings(
            modes: [inherited, advanced], defaultModeID: inherited.id,
            generation: GenerationSelection(provider: .chatGPT, model: "account-model")
        )
        let loaded = try roundTrip(settings)

        XCTAssertEqual(loaded.generationSelection(for: loaded.modes[0]), settings.generation)
        XCTAssertEqual(loaded.generationSelection(for: loaded.modes[1]).provider, .legacyCLI)
        XCTAssertEqual(loaded.modes[0].model, "sonnet")
        XCTAssertEqual(loaded.modes[1].model, "legacy-model")
        XCTAssertEqual(loaded.modes.map(\.id), settings.modes.map(\.id))
        XCTAssertEqual(loaded, settings)
    }

    func testSettingsRejectUnknownProviderAndKeepRolloutDefault() throws {
        XCTAssertEqual(SableSettings.standard.generation.provider, .legacyCLI)
        for selection in [#"{"model":"sonnet"}"#, #"{"provider":"unknown"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(GenerationSelection.self, from: Data(selection.utf8)))
        }
    }

    func testProviderFailureDoesNotInvokeFallback() async throws {
        let chosen = RecordingGenerator(failure: .notImplemented(.chatGPT))
        let paid = RecordingGenerator()
        let cli = RecordingGenerator()
        let service = GenerationService(chatGPT: chosen, openRouter: paid, cli: cli)

        do {
            _ = try await service.rewrite(request(.chatGPT))
            XCTFail("Expected explicit provider error")
        } catch {
            XCTAssertEqual(error as? GenerationError, .notImplemented(.chatGPT))
        }
        let counts = await (chosen.calls, paid.calls, cli.calls)
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
    }

    func testExplicitOpenRouterRoutesOnlyToPaidAdapter() async throws {
        let direct = RecordingGenerator()
        let paid = RecordingGenerator()
        let cli = RecordingGenerator()
        let service = GenerationService(chatGPT: direct, openRouter: paid, cli: cli)

        let output = try await service.rewrite(request(.openRouter))

        XCTAssertEqual(output, "complete")
        let counts = await (direct.calls, paid.calls, cli.calls)
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 0)
    }

    func testCLIBridgePreservesLegacyInvocationWithoutLaunchingProcess() async throws {
        let process = ContractProcessClient()
        let service = GenerationService(cli: CLIGenerationAdapter(processClient: process))
        let request = GenerationRequest(
            selection: GenerationSelection(provider: .legacyCLI, model: "not-a-cli-model"),
            instruction: "Rewrite", selectedText: "Original", timeoutSeconds: 42,
            cli: CLIGenerationContext(
                runtimeID: .codex, runtimeSettings: RuntimeSettings(codexPath: "/custom/codex"),
                cwd: URL(fileURLWithPath: "/tmp"), model: "legacy-model"
            )
        )

        let output = try await service.rewrite(request)
        let recorded = await process.invocation
        let invocation = try XCTUnwrap(recorded)

        XCTAssertEqual(output, "rewritten")
        XCTAssertEqual(invocation.command, "/custom/codex")
        XCTAssertEqual(invocation.timeout, 42)
        XCTAssertTrue(invocation.arguments.contains("legacy-model"))
        XCTAssertFalse(invocation.arguments.contains("not-a-cli-model"))
        XCTAssertEqual(invocation.stdin, PromptBuilder.build(
            instruction: "Rewrite", selectedText: "Original", screenshotPath: ""
        ))
    }

    func testUnconfiguredDirectAdaptersFailWithoutNetworking() async {
        for provider in [GenerationProvider.chatGPT, .openRouter] {
            do {
                _ = try await GenerationService().rewrite(request(provider))
                XCTFail("Expected unavailable adapter")
            } catch {
                XCTAssertEqual(error as? ConnectionError, .notImplemented)
            }
        }
    }

    func testCancelledTaskDoesNotStartAdapter() async {
        let adapter = RecordingGenerator()
        let service = GenerationService(chatGPT: adapter)
        let request = request(.chatGPT)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.rewrite(request)
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let calls = await adapter.calls
        XCTAssertEqual(calls, 0)
    }

    private func request(_ provider: GenerationProvider) -> GenerationRequest {
        GenerationRequest(selection: GenerationSelection(provider: provider), instruction: "", selectedText: "Text")
    }

    private func roundTrip(_ settings: SableSettings) throws -> SableSettings {
        try JSONDecoder().decode(SableSettings.self, from: JSONEncoder().encode(settings))
    }
}

private actor RecordingGenerator: TextGenerating {
    var calls = 0
    let failure: GenerationError?

    init(failure: GenerationError? = nil) { self.failure = failure }

    func rewrite(_ request: GenerationRequest) async throws -> String {
        calls += 1
        if let failure { throw failure }
        return "complete"
    }
}

private actor ContractProcessClient: ProcessClient {
    var invocation: ProcessInvocation?

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        self.invocation = invocation
        return ProcessResult(stdout: #"{"type":"item.completed","item":{"type":"agent_message","text":"rewritten"}}"#)
    }
}
