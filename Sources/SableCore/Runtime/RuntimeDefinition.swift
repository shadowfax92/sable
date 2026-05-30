import Foundation

public enum RuntimeID: String, Codable, Equatable, Sendable {
    case claude
    case codex
}

public struct RuntimeInvocationRequest: Equatable, Sendable {
    public var cwd: URL
    public var prompt: String
    public var timeoutSeconds: TimeInterval
    public var model: String

    public init(cwd: URL, prompt: String, timeoutSeconds: TimeInterval, model: String = "default") {
        self.cwd = cwd
        self.prompt = prompt
        self.timeoutSeconds = timeoutSeconds
        self.model = model
    }

    /// The `--model` flag pair, or empty when the mode leaves the model on the
    /// CLI's own default. Both `claude -p` and `codex exec` accept `--model`, so
    /// the two harnesses share this.
    public var modelArguments: [String] {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "default" else {
            return []
        }
        return ["--model", trimmed]
    }
}

public struct RuntimeModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public protocol RuntimeHarness: Sendable {
    var id: RuntimeID { get }
    var displayName: String { get }
    var binaryCandidates: [String] { get }

    /// Builds the exact CLI process invocation for Sable's one-shot edit request.
    func buildInvocation(_ request: RuntimeInvocationRequest) -> ProcessInvocation

    /// Extracts the paste-ready replacement text from the runtime's JSON stream.
    func parseResult(stdout: String) throws -> String
}

public struct RuntimeDefinition: Sendable {
    private let harness: any RuntimeHarness

    public var id: RuntimeID { harness.id }
    public var displayName: String { harness.displayName }
    public var binaryCandidates: [String] { harness.binaryCandidates }

    public init(harness: any RuntimeHarness) {
        self.harness = harness
    }

    /// Builds the process invocation by delegating to the selected runtime harness.
    public func buildInvocation(_ request: RuntimeInvocationRequest) -> ProcessInvocation {
        harness.buildInvocation(request)
    }

    /// Parses stdout by delegating to the harness that owns that CLI's stream format.
    public func parseResult(stdout: String) throws -> String {
        try harness.parseResult(stdout: stdout)
    }
}

public enum RuntimeDefinitions {
    public static let claude = RuntimeDefinition(harness: ClaudeRuntimeHarness())
    public static let codex = RuntimeDefinition(harness: CodexRuntimeHarness())

    public static func definition(for id: RuntimeID) -> RuntimeDefinition {
        switch id {
        case .claude:
            claude
        case .codex:
            codex
        }
    }

    public static let defaultModel = RuntimeModelOption(id: "default", label: "Default (CLI config)")

    /// Curated model choices per harness for the mode editor. Mirrors Riff's
    /// list; "default" leaves the model unset so the CLI's own config decides.
    public static func models(for id: RuntimeID) -> [RuntimeModelOption] {
        switch id {
        case .claude:
            return [
                defaultModel,
                RuntimeModelOption(id: "sonnet", label: "Sonnet"),
                RuntimeModelOption(id: "opus", label: "Opus"),
                RuntimeModelOption(id: "haiku", label: "Haiku"),
                RuntimeModelOption(id: "claude-sonnet-4-5", label: "claude-sonnet-4-5"),
                RuntimeModelOption(id: "claude-opus-4-5", label: "claude-opus-4-5"),
            ]
        case .codex:
            return [
                defaultModel,
                RuntimeModelOption(id: "gpt-5.5", label: "gpt-5.5"),
                RuntimeModelOption(id: "gpt-5.4", label: "gpt-5.4"),
                RuntimeModelOption(id: "gpt-5.4-mini", label: "gpt-5.4-mini"),
                RuntimeModelOption(id: "gpt-5-codex", label: "gpt-5-codex"),
                RuntimeModelOption(id: "codex-mini-latest", label: "Codex Mini"),
            ]
        }
    }

    /// Human label for a stored model id, falling back to the raw id for custom
    /// values the catalog doesn't list.
    public static func modelLabel(for model: String, runtime: RuntimeID) -> String {
        models(for: runtime).first { $0.id == model }?.label ?? model
    }
}

enum RuntimeOutputParsing {
    static func parseJSONLines(_ stdout: String) -> [[String: Any]] {
        let lines = stdout.split(whereSeparator: \.isNewline).map(String.init)
        let candidates = lines.isEmpty ? [stdout] : lines
        return candidates.compactMap { line in
            guard let data = line.data(using: .utf8) else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    static func firstString(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
