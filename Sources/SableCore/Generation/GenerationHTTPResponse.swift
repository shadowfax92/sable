import Foundation

/// Consumes one HTTP exchange. The caller owns the whole-operation deadline;
/// this layer owns body limits, HTTP admission errors and stream content types.
func generationJSON(client: any GenerationHTTPClient, request: URLRequest, provider: GenerationProvider) async throws -> [String: Any] {
    let credential = generationCredential(in: request)
    var status: Int?
    var requestID: String?
    var body = Data()
    do {
        for try await event in client.events(for: request) {
            try Task.checkCancellation()
            switch event {
            case .response(let code, _, let id):
                guard status == nil else { throw GenerationError.invalidResponse }
                status = code; requestID = id
            case .data(let data):
                guard status != nil else { throw GenerationError.invalidResponse }
                body.append(data)
                guard body.count <= 4_194_304 else { throw GenerationError.responseTooLarge }
            }
        }
        try Task.checkCancellation()
        guard let status else { throw GenerationError.invalidResponse }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw GenerationError.providerFailure(GenerationFailure(provider: provider, status: status, payload: object ?? [:], requestID: requestID, redacting: credential))
        }
        guard let object else { throw GenerationError.invalidResponse }
        return object
    } catch { throw generationNetworkError(error) }
}

func generationTextStream(client: any GenerationHTTPClient, request: URLRequest, provider: GenerationProvider) async throws -> String {
    let credential = generationCredential(in: request)
    var status: Int?
    var requestID: String?
    var failureBody = Data()
    var parser = ServerSentEvents()
    var consumer = GenerationStreamConsumer(provider: provider)
    do {
        for try await event in client.events(for: request) {
            try Task.checkCancellation()
            switch event {
            case .response(let code, let contentType, let id):
                guard status == nil else { throw GenerationError.invalidResponse }
                status = code; requestID = id
                if (200..<300).contains(code) {
                    // ChatGPT plan inference can omit Content-Type on a valid
                    // SSE response. In that case framing and the provider's
                    // completed terminal object below still gate delivery;
                    // explicit wrong media types and OpenRouter stay strict.
                    if let contentType {
                        guard contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream"
                        else { throw GenerationError.invalidResponse }
                    } else if provider != .chatGPT {
                        throw GenerationError.invalidResponse
                    }
                }
            case .data(let data):
                guard let status else { throw GenerationError.invalidResponse }
                if !(200..<300).contains(status) {
                    failureBody.append(data)
                    guard failureBody.count <= 65_536 else { throw GenerationError.responseTooLarge }
                } else {
                    for event in try parser.append(data) {
                        if let text = try consumer.consume(event, status: status, requestID: requestID, redacting: credential) {
                            try Task.checkCancellation()
                            return text
                        }
                    }
                }
            }
        }
        try Task.checkCancellation()
        guard let status else { throw GenerationError.invalidResponse }
        if !(200..<300).contains(status) {
            let object = (try? JSONSerialization.jsonObject(with: failureBody)) as? [String: Any] ?? [:]
            throw GenerationError.providerFailure(GenerationFailure(provider: provider, status: status, payload: object, requestID: requestID, redacting: credential))
        }
        throw GenerationError.interrupted
    } catch { throw generationNetworkError(error) }
}

/// Keep the active bearer available only for scrubbing server diagnostic fields.
/// ConnectionSecret prevents accidental reflection/logging of this local value.
private func generationCredential(in request: URLRequest) -> ConnectionSecret? {
    guard let authorization = request.value(forHTTPHeaderField: "Authorization"), authorization.hasPrefix("Bearer ") else { return nil }
    return ConnectionSecret(String(authorization.dropFirst(7)))
}
