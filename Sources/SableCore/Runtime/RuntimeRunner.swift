import Foundation

public struct RuntimeRunner {
    public struct Request: Equatable {
        public let runtimeID: RuntimeID
        public let runtimeSettings: RuntimeSettings
        public let cwd: URL
        public let timeoutSeconds: TimeInterval
        public let prompt: String
        public let model: String

        public init(
            runtimeID: RuntimeID,
            runtimeSettings: RuntimeSettings = RuntimeSettings(),
            cwd: URL,
            timeoutSeconds: TimeInterval,
            prompt: String,
            model: String = "default"
        ) {
            self.runtimeID = runtimeID
            self.runtimeSettings = runtimeSettings
            self.cwd = cwd
            self.timeoutSeconds = timeoutSeconds
            self.prompt = prompt
            self.model = model
        }
    }

    private let processClient: any ProcessClient

    public init(processClient: any ProcessClient = FoundationProcessClient()) {
        self.processClient = processClient
    }

    /// Runs the configured CLI runtime once and returns the paste-ready replacement text.
    public func run(_ request: Request) async throws -> String {
        let definition = RuntimeDefinitions.definition(for: request.runtimeID)
        var invocation = definition.buildInvocation(RuntimeInvocationRequest(
            cwd: request.cwd,
            prompt: request.prompt,
            timeoutSeconds: request.timeoutSeconds,
            model: request.model
        ))
        let command = request.runtimeSettings.command(for: request.runtimeID)
        if !command.isEmpty {
            invocation.command = command
        }
        let result = try await processClient.run(invocation)

        if result.timedOut {
            throw SableError.runtimeTimedOut(definition.displayName)
        }
        if result.exitCode != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SableError.runtimeFailed(
                definition.displayName,
                message.isEmpty ? "exit \(result.exitCode)" : message
            )
        }
        return try definition.parseResult(stdout: result.stdout)
    }
}
