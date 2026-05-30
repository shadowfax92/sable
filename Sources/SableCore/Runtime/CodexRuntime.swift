import Foundation

public struct CodexRuntimeHarness: RuntimeHarness {
    public let id: RuntimeID = .codex
    public let displayName = "Codex CLI"
    public let binaryCandidates = ["codex"]

    public init() {}

    public func buildInvocation(_ request: RuntimeInvocationRequest) -> ProcessInvocation {
        ProcessInvocation(
            command: binaryCandidates[0],
            arguments: [
                "exec",
                "--json",
                "--skip-git-repo-check",
                "--dangerously-bypass-approvals-and-sandbox",
                "-C", request.cwd.path,
            ] + request.modelArguments,
            stdin: request.prompt,
            workingDirectory: request.cwd,
            timeout: request.timeoutSeconds
        )
    }

    public func parseResult(stdout: String) throws -> String {
        var text = ""

        for rawObject in RuntimeOutputParsing.parseJSONLines(stdout) {
            let object = rawObject["msg"] as? [String: Any] ?? rawObject
            let type = object["type"] as? String ?? ""

            if type == "agent_message_delta", let delta = object["delta"] as? String {
                text += delta
            } else if type == "agent_message", let message = object["message"] as? String {
                text = message
            } else if type == "agent_message", let message = object["text"] as? String {
                text = message
            } else if type == "item.completed",
                      let item = object["item"] as? [String: Any],
                      item["type"] as? String == "agent_message",
                      let message = item["text"] as? String {
                text = message
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SableError.runtimeResultMissing(displayName)
        }
        return trimmed
    }
}
