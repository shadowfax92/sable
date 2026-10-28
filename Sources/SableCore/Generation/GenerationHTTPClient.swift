import Foundation

/// Headers and body chunks share one sequence so cancellation also covers the
/// wait before the first byte. Test clients can supply the exact same boundary.
public enum GenerationHTTPEvent: Sendable {
    case response(status: Int, contentType: String?, requestID: String?)
    case data(Data)
}

public protocol GenerationHTTPClient: Sendable {
    func events(for request: URLRequest) -> AsyncThrowingStream<GenerationHTTPEvent, Error>
}

/// Reuses one ephemeral session without cookies, credential storage or redirects.
/// The delegate owns request correlation; terminating a consumer cancels its task.
public final class URLSessionGenerationHTTPClient: GenerationHTTPClient, @unchecked Sendable {
    public static let shared = URLSessionGenerationHTTPClient()
    private let delegate = GenerationSessionDelegate()
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        // An inactivity timeout is only a secondary guard. Generation's deadline
        // bounds the entire operation, including discovery and endless heartbeats.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func events(for request: URLRequest) -> AsyncThrowingStream<GenerationHTTPEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let task = session.dataTask(with: request)
            delegate.register(task, continuation: continuation)
            continuation.onTermination = { [weak delegate] _ in
                delegate?.remove(task.taskIdentifier)
                task.cancel()
            }
            task.resume()
        }
    }
}

/// URLSession delivers callbacks serially, but stream termination runs on the
/// consumer's executor. The lock protects only the task-to-continuation registry;
/// yielding and cancellation happen outside it to avoid reentrant deadlocks.
private final class GenerationSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<GenerationHTTPEvent, Error>.Continuation
    private let lock = NSLock()
    private var continuations: [Int: Continuation] = [:]

    func register(_ task: URLSessionTask, continuation: Continuation) {
        lock.lock()
        continuations[task.taskIdentifier] = continuation
        lock.unlock()
    }

    @discardableResult
    func remove(_ id: Int) -> Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuations.removeValue(forKey: id)
    }

    private func yield(_ event: GenerationHTTPEvent, task: URLSessionTask) {
        lock.lock()
        let continuation = continuations[task.taskIdentifier]
        lock.unlock()
        if let continuation, case .dropped = continuation.yield(event) {
            // Never drop a body chunk silently: it would corrupt SSE framing.
            remove(task.taskIdentifier)?.finish(throwing: GenerationError.responseTooLarge)
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            remove(dataTask.taskIdentifier)?.finish(throwing: GenerationError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        yield(.response(status: response.statusCode,
                        contentType: response.value(forHTTPHeaderField: "Content-Type"),
                        requestID: response.value(forHTTPHeaderField: "x-request-id")), task: dataTask)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        yield(.data(data), task: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = remove(task.taskIdentifier)
        if let error { continuation?.finish(throwing: error) }
        else { continuation?.finish() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // An authenticated request must never forward its credential to a new URL.
        completionHandler(nil)
    }
}

/// One monotonic deadline wraps credentials, catalog, headers and body together.
/// Both children cooperate with cancellation; the HTTP stream tears down its task
/// when the losing consumer is cancelled, even while waiting for response headers.
func withGenerationDeadline<T: Sendable>(
    seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try Task.checkCancellation()
    guard seconds.isFinite, seconds > 0 else { throw GenerationError.deadlineExceeded }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw GenerationError.deadlineExceeded
        }
        defer { group.cancelAll() }
        let result = try await group.next()!
        try Task.checkCancellation()
        return result
    }
}

func generationHTTPRequest(url: String, secret: ConnectionSecret? = nil, body: [String: Any]? = nil) throws -> URLRequest {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = body == nil ? "GET" : "POST"
    request.setValue(body == nil ? "application/json" : "text/event-stream", forHTTPHeaderField: "Accept")
    if let secret { request.setValue("Bearer \(secret.rawValue)", forHTTPHeaderField: "Authorization") }
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    return request
}

/// HTTP diagnostics are classified before the body leaves this module. Raw
/// messages and URLSession errors can contain input or credentials and never
/// become user-visible errors, settings, history or debug descriptions.
func generationNetworkError(_ error: Error) -> Error {
    if Task.isCancelled || error is CancellationError { return CancellationError() }
    if error is GenerationError || error is ConnectionError { return error }
    return GenerationError.networkUnavailable
}
