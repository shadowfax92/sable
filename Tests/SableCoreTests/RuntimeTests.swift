import XCTest
@testable import SableCore

final class RuntimeTests: XCTestCase {
    func testClaudeInvocationUsesRiffStyleStreamJSONAndBypassPermissions() {
        let request = RuntimeInvocationRequest(
            cwd: URL(fileURLWithPath: "/tmp/sable"),
            prompt: "prompt",
            timeoutSeconds: 60
        )

        let invocation = RuntimeDefinitions.claude.buildInvocation(request)

        XCTAssertEqual(invocation.command, "claude")
        XCTAssertEqual(invocation.stdin, "prompt")
        XCTAssertEqual(invocation.workingDirectory?.path, "/tmp/sable")
        XCTAssertEqual(invocation.timeout, 60)
        XCTAssertTrue(invocation.arguments.contains("-p"))
        XCTAssertTrue(hasPair(invocation.arguments, "--output-format", "stream-json"))
        XCTAssertTrue(hasPair(invocation.arguments, "--permission-mode", "bypassPermissions"))
        XCTAssertTrue(hasPair(invocation.arguments, "--add-dir", "/tmp/sable"))
    }

    func testModelFlagAppendedWhenSet() {
        let request = RuntimeInvocationRequest(
            cwd: URL(fileURLWithPath: "/tmp/sable"),
            prompt: "prompt",
            timeoutSeconds: 60,
            model: "opus"
        )

        XCTAssertTrue(hasPair(RuntimeDefinitions.claude.buildInvocation(request).arguments, "--model", "opus"))
        XCTAssertTrue(hasPair(RuntimeDefinitions.codex.buildInvocation(request).arguments, "--model", "opus"))
    }

    func testModelFlagOmittedForDefault() {
        let request = RuntimeInvocationRequest(
            cwd: URL(fileURLWithPath: "/tmp/sable"),
            prompt: "prompt",
            timeoutSeconds: 60,
            model: "default"
        )

        XCTAssertFalse(RuntimeDefinitions.claude.buildInvocation(request).arguments.contains("--model"))
        XCTAssertFalse(RuntimeDefinitions.codex.buildInvocation(request).arguments.contains("--model"))
    }

    func testCodexInvocationUsesRiffStyleExecJSON() {
        let request = RuntimeInvocationRequest(
            cwd: URL(fileURLWithPath: "/tmp/sable"),
            prompt: "prompt",
            timeoutSeconds: 60
        )

        let invocation = RuntimeDefinitions.codex.buildInvocation(request)

        XCTAssertEqual(invocation.command, "codex")
        XCTAssertTrue(invocation.arguments.starts(with: [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--dangerously-bypass-approvals-and-sandbox",
        ]))
        XCTAssertTrue(hasPair(invocation.arguments, "-C", "/tmp/sable"))
        XCTAssertEqual(invocation.stdin, "prompt")
    }

    func testParsesClaudeResultOutput() throws {
        let stdout = """
        {"type":"system","subtype":"init","session_id":"abc"}
        {"type":"result","result":"Corrected text.","is_error":false}
        """

        XCTAssertEqual(try RuntimeDefinitions.claude.parseResult(stdout: stdout), "Corrected text.")
    }

    func testParsesClaudeAssistantTextFallback() throws {
        let stdout = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"Corrected "},{"type":"text","text":"text."}]}}
        """

        XCTAssertEqual(try RuntimeDefinitions.claude.parseResult(stdout: stdout), "Corrected text.")
    }

    func testThrowsOnClaudeErrorResult() {
        let stdout = #"{"type":"result","is_error":true,"result":"Bad request"}"#

        XCTAssertThrowsError(try RuntimeDefinitions.claude.parseResult(stdout: stdout)) { error in
            XCTAssertEqual(error as? SableError, .runtimeFailed("Claude Code", "Bad request"))
        }
    }

    func testParsesCodexDeltaOutput() throws {
        let stdout = """
        {"msg":{"type":"session_configured","session_id":"codex-session"}}
        {"msg":{"type":"agent_message_delta","delta":"Corrected "}}
        {"msg":{"type":"agent_message_delta","delta":"text."}}
        """

        XCTAssertEqual(try RuntimeDefinitions.codex.parseResult(stdout: stdout), "Corrected text.")
    }

    func testParsesCurrentCodexItemCompletedOutput() throws {
        let stdout = """
        {"type":"thread.started","thread_id":"codex-thread"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Corrected text."}}
        """

        XCTAssertEqual(try RuntimeDefinitions.codex.parseResult(stdout: stdout), "Corrected text.")
    }

    func testRuntimeSettingsReturnExplicitCommands() {
        let settings = RuntimeSettings(
            claudePath: " /custom/claude ",
            codexPath: " /custom/codex "
        )

        XCTAssertEqual(settings.command(for: .claude), "/custom/claude")
        XCTAssertEqual(settings.command(for: .codex), "/custom/codex")
    }

    func testRuntimeRunnerOverridesCommandFromSettings() async throws {
        let client = RecordingProcessClient(result: ProcessResult(stdout: """
        {"msg":{"type":"agent_message_delta","delta":"done"}}
        """))
        let runner = RuntimeRunner(processClient: client)

        _ = try await runner.run(RuntimeRunner.Request(
            runtimeID: .codex,
            runtimeSettings: RuntimeSettings(codexPath: "/custom/codex"),
            cwd: URL(fileURLWithPath: "/tmp/sable"),
            timeoutSeconds: 60,
            prompt: "prompt"
        ))

        let invocation = await client.lastInvocation
        XCTAssertEqual(invocation?.command, "/custom/codex")
    }

    func testRuntimeRunnerThrowsOnTimeout() async {
        let client = RecordingProcessClient(result: ProcessResult(stdout: "", exitCode: 15, timedOut: true))
        let runner = RuntimeRunner(processClient: client)

        do {
            _ = try await runner.run(RuntimeRunner.Request(
                runtimeID: .claude,
                cwd: URL(fileURLWithPath: "/tmp/sable"),
                timeoutSeconds: 1,
                prompt: "prompt"
            ))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? SableError, .runtimeTimedOut("Claude Code"))
        }
    }

    private func hasPair(_ args: [String], _ key: String, _ value: String) -> Bool {
        zip(args, args.dropFirst()).contains { $0 == key && $1 == value }
    }
}

private actor RecordingProcessClient: ProcessClient {
    let result: ProcessResult
    var lastInvocation: ProcessInvocation?

    init(result: ProcessResult) {
        self.result = result
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        lastInvocation = invocation
        return result
    }
}
