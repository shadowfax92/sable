import Foundation
import Network

struct ConnectionCallback: Sendable {
    let code: String?
    let clientID: String?
    let error: String?
}

/// One listener belongs to one sign-in attempt. Injection lets lifecycle tests
/// stop at the HTTP seam; production always uses the native loopback listener.
protocol ConnectionCallbackListening: Sendable {
    func start(state: String) async throws -> URL
    func callback() async throws -> ConnectionCallback
    func cancel()
}

/// Minimal bounded HTTP, serialized on one queue. Unrelated tabs, malformed
/// requests and wrong state close only that peer, preserving the genuine attempt.
/// Every completion funnels through finish so cancellation resumes waiters once.
final class LoopbackConnectionListener: ConnectionCallbackListening, @unchecked Sendable {
    private let queue = DispatchQueue(label: "sable.oauth.loopback")
    private var listener: NWListener?
    private var port: UInt16?
    private var state = ""
    private var readyWaiter: CheckedContinuation<URL, Error>?
    private var callbackWaiter: CheckedContinuation<ConnectionCallback, Error>?
    private var outcome: Result<ConnectionCallback, Error>?
    private var peers: [UUID: Peer] = [:]
    private let maximumHeaderSize = 16_384

    deinit {
        listener?.cancel()
        for peer in peers.values { peer.timeout?.cancel(); peer.connection.cancel() }
    }

    private final class Peer {
        let connection: NWConnection
        var data = Data()
        var timeout: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    func start(state: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.outcome == nil else { continuation.resume(throwing: CancellationError()); return }
                    guard self.listener == nil else {
                        continuation.resume(throwing: ConnectionError.listenerUnavailable); return
                    }
                    self.state = state
                    self.readyWaiter = continuation
                    do {
                        let parameters = NWParameters.tcp
                        // Do not bind wildcard or localhost: only this literal IPv4
                        // address is registered, authorized, and exchanged.
                        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self] status in self?.changed(status) }
                        listener.newConnectionHandler = { [weak self] connection in
                            guard let self else { connection.cancel(); return }
                            self.accept(connection)
                        }
                        listener.start(queue: self.queue)
                    } catch { self.finish(.failure(ConnectionError.listenerUnavailable)) }
                }
            }
        } onCancel: { self.cancel() }
    }

    func callback() async throws -> ConnectionCallback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.outcome { continuation.resume(with: result) }
                    else if self.callbackWaiter != nil {
                        continuation.resume(throwing: ConnectionError.listenerUnavailable)
                    } else { self.callbackWaiter = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }

    private func changed(_ status: NWListener.State) {
        guard outcome == nil else { return }
        switch status {
        case .ready:
            guard let port = listener?.port?.rawValue,
                  let url = URL(string: "http://127.0.0.1:\(port)/auth/callback") else {
                finish(.failure(ConnectionError.listenerUnavailable)); return
            }
            self.port = port
            let waiter = readyWaiter
            readyWaiter = nil
            waiter?.resume(returning: url)
        case .failed:
            finish(.failure(ConnectionError.listenerUnavailable))
        case .cancelled:
            finish(.failure(CancellationError()))
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard outcome == nil, peers.count < 8 else { connection.cancel(); return }
        let id = UUID()
        let peer = Peer(connection)
        peers[id] = peer
        let timeout = DispatchWorkItem { [weak self] in self?.close(id) }
        peer.timeout = timeout
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
        connection.start(queue: queue)
        receive(id)
    }

    private func receive(_ id: UUID) {
        guard let peer = peers[id] else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: maximumHeaderSize + 1 - peer.data.count) {
            [weak self] data, _, complete, error in
            guard let self, let peer = self.peers[id], self.outcome == nil else { return }
            if let data { peer.data.append(data) }
            guard peer.data.count <= self.maximumHeaderSize else { self.reject(id); return }
            if peer.data.range(of: Data("\r\n\r\n".utf8)) != nil {
                guard let callback = self.parse(peer.data) else { self.reject(id); return }
                let response = Self.response(status: "200 OK", body: "Sign-in received. You can return to Sable.")
                peer.connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                    self?.finish(.success(callback))
                })
            } else if complete || error != nil { self.close(id) }
            else { self.receive(id) }
        }
    }

    private func parse(_ data: Data) -> ConnectionCallback? {
        guard let text = String(data: data, encoding: .utf8), let end = text.range(of: "\r\n\r\n") else { return nil }
        let lines = text[..<end.lowerBound].components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "GET", ["HTTP/1.1", "HTTP/1.0"].contains(request[2]),
              request[1].hasPrefix("/"), !request[1].hasPrefix("//"),
              let components = URLComponents(string: String(request[1]).replacingOccurrences(of: "+", with: "%20")),
              components.percentEncodedPath == "/auth/callback",
              components.fragment == nil, components.host == nil else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { return nil }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let port, headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value else { return nil }
            values[item.name] = value
        }
        guard values["state"] == state else { return nil }
        let code = values["code"].flatMap { $0.isEmpty ? nil : $0 }
        let error = values["error"].flatMap { $0.isEmpty ? nil : $0 }
        guard (code != nil) != (error != nil) else { return nil }
        return ConnectionCallback(code: code, clientID: values["client_id"], error: error)
    }

    private func reject(_ id: UUID) {
        guard let peer = peers[id] else { return }
        peer.connection.send(content: Self.response(status: "400 Bad Request", body: "Unrecognized sign-in callback."),
                             completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }

    private static func response(status: String, body: String) -> Data {
        Data(("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n"
              + "Connection: close\r\nCache-Control: no-store\r\n\r\n" + body).utf8)
    }

    private func close(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.timeout?.cancel()
        peer.connection.cancel()
    }

    private func finish(_ result: Result<ConnectionCallback, Error>) {
        guard outcome == nil else { return }
        outcome = result
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for id in Array(peers.keys) { close(id) }
        let ready = readyWaiter
        readyWaiter = nil
        if case .failure(let error) = result { ready?.resume(throwing: error) }
        let callback = callbackWaiter
        callbackWaiter = nil
        callback?.resume(with: result)
    }
}
