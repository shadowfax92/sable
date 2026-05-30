import Foundation

public struct ProcessInvocation: Equatable, Sendable {
    public var command: String
    public var arguments: [String]
    public var stdin: String?
    public var workingDirectory: URL?
    public var timeout: TimeInterval?

    public init(
        command: String,
        arguments: [String],
        stdin: String? = nil,
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.stdin = stdin
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }
}

public struct ProcessResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var timedOut: Bool

    public init(stdout: String, stderr: String = "", exitCode: Int32 = 0, timedOut: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

public protocol ProcessClient: Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult
}

public enum ProcessClientError: Error, Equatable {
    case failedToDecodeOutput
}

public final class FoundationProcessClient: ProcessClient, @unchecked Sendable {
    private let environment: [String: String]

    public init(environment: [String: String] = RuntimeEnvironment.subprocessEnvironment()) {
        self.environment = environment
    }

    /// Runs a subprocess with stdin, timeout, and non-blocking output drains for CLI runtimes.
    public func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let state = ProcessRunState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.begin(continuation) else {
                    return
                }

                let process = Process()
                if invocation.command.contains("/") {
                    process.executableURL = URL(fileURLWithPath: invocation.command)
                    process.arguments = invocation.arguments
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = [invocation.command] + invocation.arguments
                }
                process.currentDirectoryURL = invocation.workingDirectory
                process.environment = environment

                let stdout = Pipe()
                let stderr = Pipe()
                let stdin = Pipe()
                let stdoutBuffer = ProcessOutputBuffer()
                let stderrBuffer = ProcessOutputBuffer()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = stdin

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        stdoutBuffer.append(data)
                    }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        stderrBuffer.append(data)
                    }
                }

                process.terminationHandler = { process in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                    stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                    guard
                        let output = stdoutBuffer.string(encoding: .utf8),
                        let error = stderrBuffer.string(encoding: .utf8)
                    else {
                        state.finish(.failure(ProcessClientError.failedToDecodeOutput))
                        return
                    }
                    state.finish(.success(ProcessResult(
                        stdout: output,
                        stderr: error,
                        exitCode: process.terminationStatus,
                        timedOut: state.didTimeOut()
                    )))
                }

                guard state.setProcess(process) else {
                    return
                }

                do {
                    try process.run()
                    guard state.processDidStart(process) else {
                        return
                    }
                    if let timeout = invocation.timeout, timeout > 0 {
                        let timeoutWorkItem = DispatchWorkItem {
                            state.markTimedOut()
                            if process.isRunning {
                                process.terminate()
                            }
                        }
                        state.setTimeoutWorkItem(timeoutWorkItem)
                        DispatchQueue.global().asyncAfter(
                            deadline: .now() + timeout,
                            execute: timeoutWorkItem
                        )
                    }
                    if let input = invocation.stdin {
                        stdin.fileHandleForWriting.write(Data(input.utf8))
                    }
                    try stdin.fileHandleForWriting.close()
                } catch {
                    state.finish(.failure(error))
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var process: Process?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completed = false
    private var cancelled = false
    private var timedOut = false

    func begin(_ continuation: CheckedContinuation<ProcessResult, Error>) -> Bool {
        lock.lock()
        if cancelled {
            completed = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setProcess(_ process: Process) -> Bool {
        lock.lock()
        if completed || cancelled {
            lock.unlock()
            return false
        }
        self.process = process
        lock.unlock()
        return true
    }

    func processDidStart(_ process: Process) -> Bool {
        lock.lock()
        let shouldCancel = cancelled || completed
        lock.unlock()
        if shouldCancel, process.isRunning {
            process.terminate()
            return false
        }
        return true
    }

    func setTimeoutWorkItem(_ workItem: DispatchWorkItem) {
        lock.lock()
        if completed {
            lock.unlock()
            workItem.cancel()
            return
        }
        timeoutWorkItem = workItem
        lock.unlock()
    }

    func markTimedOut() {
        lock.lock()
        if !completed {
            timedOut = true
        }
        lock.unlock()
    }

    func didTimeOut() -> Bool {
        lock.lock()
        let value = timedOut
        lock.unlock()
        return value
    }

    func finish(_ result: Result<ProcessResult, Error>) {
        let continuation = takeContinuation(markCompleted: true)
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        cancelled = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let process = process
        let continuation = continuation
        self.continuation = nil
        self.process = nil
        if continuation != nil {
            completed = true
        }
        lock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func takeContinuation(markCompleted: Bool) -> CheckedContinuation<ProcessResult, Error>? {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return nil
        }
        if markCompleted {
            completed = true
        }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let continuation = continuation
        self.continuation = nil
        process = nil
        lock.unlock()
        return continuation
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string(encoding: String.Encoding) -> String? {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: encoding)
    }
}
