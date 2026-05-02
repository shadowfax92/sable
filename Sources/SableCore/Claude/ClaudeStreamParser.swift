import Foundation

public enum ClaudeStreamParser {
    /// Extracts Claude Code's final result text from newline-delimited stream-json output.
    public static func extractResultText(from stdout: String) throws -> String {
        var lastResult: String?
        var lastError: String?
        let lines = stdout.split(whereSeparator: \.isNewline).map(String.init)
        let candidates = lines.isEmpty ? [stdout] : lines

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let isError = object["is_error"] as? Bool ?? false
            let result = object["result"] as? String

            if isError {
                lastError = result ?? "Claude returned an error"
                continue
            }

            if let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastResult = result
            }
        }

        if let lastError {
            throw SableError.claudeFailed(lastError)
        }

        guard let lastResult else {
            throw SableError.claudeResultMissing
        }

        return lastResult.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
