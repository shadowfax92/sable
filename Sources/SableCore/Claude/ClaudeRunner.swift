import Foundation

private final class ProcessRunState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.browseros.sable.claude-runner-state")
    private var timedOut = false
    private var timeoutWorkItem: DispatchWorkItem?

    func markTimedOut() {
        queue.sync {
            timedOut = true
        }
    }

    func didTimeOut() -> Bool {
        queue.sync {
            timedOut
        }
    }

    func setTimeoutWorkItem(_ workItem: DispatchWorkItem) {
        queue.sync {
            timeoutWorkItem = workItem
        }
    }

    func cancelTimeout() {
        queue.sync {
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
        }
    }
}

public struct ClaudeRunner {
    public struct Request: Equatable {
        public let command: String
        public let args: [String]
        public let cwd: URL
        public let timeoutSeconds: TimeInterval
        public let prompt: String

        public init(
            command: String,
            args: [String],
            cwd: URL,
            timeoutSeconds: TimeInterval,
            prompt: String
        ) {
            self.command = command
            self.args = args
            self.cwd = cwd
            self.timeoutSeconds = timeoutSeconds
            self.prompt = prompt
        }
    }

    public init() {}

    /// Runs Claude Code as a one-shot process and returns the paste-ready result text.
    public func run(_ request: Request) async throws -> String {
        let process = Process()
        if request.command.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: request.command)
            process.arguments = request.args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [request.command] + request.args
        }
        process.currentDirectoryURL = request.cwd

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            let state = ProcessRunState()

            process.terminationHandler = { process in
                state.cancelTimeout()
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

                if state.didTimeOut() {
                    continuation.resume(throwing: SableError.claudeTimedOut)
                    return
                }

                if process.terminationStatus != 0 {
                    let message = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: SableError.claudeFailed(
                            message.isEmpty ? "exit \(process.terminationStatus)" : message
                        )
                    )
                    return
                }

                do {
                    continuation.resume(returning: try ClaudeStreamParser.extractResultText(from: stdoutText))
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            do {
                try process.run()
                if let data = request.prompt.data(using: .utf8) {
                    stdin.fileHandleForWriting.write(data)
                }
                try stdin.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            let timeoutWorkItem = DispatchWorkItem {
                state.markTimedOut()
                if process.isRunning {
                    process.terminate()
                }
            }
            state.setTimeoutWorkItem(timeoutWorkItem)
            DispatchQueue.global().asyncAfter(
                deadline: .now() + request.timeoutSeconds,
                execute: timeoutWorkItem
            )
        }
    }
}
