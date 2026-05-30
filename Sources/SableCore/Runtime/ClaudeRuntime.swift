import Foundation

public struct ClaudeRuntimeHarness: RuntimeHarness {
    public let id: RuntimeID = .claude
    public let displayName = "Claude Code"
    public let binaryCandidates = ["claude", "openclaude"]

    public init() {}

    public func buildInvocation(_ request: RuntimeInvocationRequest) -> ProcessInvocation {
        ProcessInvocation(
            command: binaryCandidates[0],
            arguments: [
                "-p",
                "--input-format", "text",
                "--output-format", "stream-json",
                "--verbose",
                "--permission-mode", "bypassPermissions",
                "--add-dir", request.cwd.path,
            ] + request.modelArguments,
            stdin: request.prompt,
            workingDirectory: request.cwd,
            timeout: request.timeoutSeconds
        )
    }

    public func parseResult(stdout: String) throws -> String {
        var textParts: [String] = []
        var resultText = ""
        var lastError: String?

        for object in RuntimeOutputParsing.parseJSONLines(stdout) {
            let type = object["type"] as? String
            if object["is_error"] as? Bool == true {
                lastError = object["result"] as? String ?? "Claude returned an error"
            } else if type == "assistant",
                      let message = object["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "text" {
                    if let text = block["text"] as? String {
                        textParts.append(text)
                    }
                }
            } else if type == "result" {
                resultText = object["result"] as? String ?? resultText
            } else if let result = object["result"] as? String {
                resultText = result
            }
        }

        if let lastError {
            throw SableError.runtimeFailed(displayName, lastError)
        }

        let text = (resultText.isEmpty ? textParts.joined() : resultText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SableError.runtimeResultMissing(displayName)
        }
        return text
    }
}
