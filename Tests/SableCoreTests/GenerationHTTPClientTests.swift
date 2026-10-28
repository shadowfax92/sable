import XCTest
@testable import SableCore

/// Exercise the real URLSession bridge with URLProtocol, without a socket or
/// credentials. stopLoading is the observable proof of actual task teardown.
final class GenerationHTTPClientTests: XCTestCase {
    func testNativeTransportCancellationBeforeHeadersAndBetweenEvents() async throws {
        for path in ["before-headers", "between-events"] {
            let scenario = UUID().uuidString + "/" + path
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GenerationURLProtocol.self]
            let client = URLSessionGenerationHTTPClient(configuration: configuration)
            let task = Task {
                try await generationTextStream(client: client, request: URLRequest(url: URL(string: "https://generation.invalid/\(scenario)")!), provider: .chatGPT)
            }
            try await waitForProtocol { GenerationURLProtocol.started(scenario) }
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            try await waitForProtocol { GenerationURLProtocol.stopped(scenario) }
        }
    }

    func testDeadlineCancelsNativeTaskBeforeHeaders() async throws {
        let scenario = UUID().uuidString + "/before-headers"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenerationURLProtocol.self]
        let client = URLSessionGenerationHTTPClient(configuration: configuration)
        do {
            _ = try await withGenerationDeadline(seconds: 0.05) {
                try await generationTextStream(client: client, request: URLRequest(url: URL(string: "https://generation.invalid/\(scenario)")!), provider: .chatGPT)
            }
            XCTFail("Expected deadline")
        } catch { XCTAssertEqual(error as? GenerationError, .deadlineExceeded) }
        try await waitForProtocol { GenerationURLProtocol.stopped(scenario) }
    }

    func testTerminalCompletionCancelsNativeTaskWithoutWaitingForEOF() async throws {
        let scenario = UUID().uuidString + "/complete"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenerationURLProtocol.self]
        let client = URLSessionGenerationHTTPClient(configuration: configuration)
        let output = try await withGenerationDeadline(seconds: 1) {
            try await generationTextStream(client: client, request: URLRequest(url: URL(string: "https://generation.invalid/\(scenario)")!), provider: .chatGPT)
        }
        XCTAssertEqual(output, "complete")
        try await waitForProtocol { GenerationURLProtocol.stopped(scenario) }
    }

    private func waitForProtocol(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("URLSession did not reach expected lifecycle state")
    }
}

private final class GenerationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var starts: Set<String> = []
    private static var stops: Set<String> = []

    static func started(_ scenario: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return starts.contains("/" + scenario)
    }
    static func stopped(_ scenario: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return stops.contains("/" + scenario)
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "generation.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock(); Self.starts.insert(path); Self.lock.unlock()
        guard !path.hasSuffix("before-headers") else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"complete\"}\n\n"
        client?.urlProtocol(self, didLoad: Data(delta.utf8))
        if path.hasSuffix("complete") {
            let terminal = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"complete"}]}]}}"#
            client?.urlProtocol(self, didLoad: Data(("data: " + terminal + "\n\n").utf8))
        }
        // Deliberately never finish: completion and cancellation must tear down
        // the native task themselves rather than waiting for server EOF.
    }

    override func stopLoading() {
        Self.lock.lock(); Self.stops.insert(request.url!.path); Self.lock.unlock()
    }
}
