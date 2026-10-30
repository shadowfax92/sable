import Foundation

struct ServerSentEvent {
    let name: String?
    let data: String
}

/// Incremental byte framing preserves UTF-8 split across network chunks and
/// implements SSE's CR, LF, CRLF, comments and multiple data fields. Only a blank
/// line dispatches an event: EOF cannot turn an unterminated frame into success.
struct ServerSentEvents {
    private var line: [UInt8] = []
    private var fields: [String] = []
    private var name: String?
    private var skipLF = false
    private var firstLine = true
    private var eventBytes = 0
    private var totalBytes = 0
    private static let eventLimit = 1_048_576
    private static let totalLimit = 16_777_216

    mutating func append(_ data: Data) throws -> [ServerSentEvent] {
        totalBytes += data.count
        guard totalBytes <= Self.totalLimit else { throw GenerationError.responseTooLarge }
        var events: [ServerSentEvent] = []
        for byte in data {
            if skipLF {
                skipLF = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                if let event = try endLine() { events.append(event) }
                skipLF = byte == 13
            } else {
                line.append(byte)
                eventBytes += 1
                guard eventBytes <= Self.eventLimit else { throw GenerationError.responseTooLarge }
            }
        }
        return events
    }

    private mutating func endLine() throws -> ServerSentEvent? {
        guard var value = String(bytes: line, encoding: .utf8) else { throw GenerationError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
        }
        if value.isEmpty {
            defer { fields.removeAll(keepingCapacity: true); name = nil; eventBytes = 0 }
            return fields.isEmpty ? nil : ServerSentEvent(name: name, data: fields.joined(separator: "\n"))
        }
        if value.hasPrefix(":") { return nil }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var fieldValue = parts.count == 2 ? String(parts[1]) : ""
        if fieldValue.hasPrefix(" ") { fieldValue.removeFirst() }
        if parts[0] == "data" { fields.append(fieldValue) }
        else if parts[0] == "event" { name = fieldValue }
        return nil
    }
}

/// Providers share framing but have different success contracts. In particular,
/// an OpenRouter stop chunk still needs [DONE], while Responses needs its complete
/// response fence; seeing text or output_text.done alone is never sufficient.
struct GenerationStreamConsumer {
    let provider: GenerationProvider
    private var text = ""
    private var stopped = false
    private var responseItems = ResponsesCompletedItems()
    // Direct rewrites request no tools. Reject even orphan lifecycle events;
    // waiting for a tool's output_item.done would miss a corrupt partial call.
    private static let responseToolEventPrefixes = [
        "response.function_call_arguments.", "response.custom_tool_call_input.",
        "response.file_search_call.", "response.web_search_call.",
        "response.image_generation_call.", "response.code_interpreter_call.",
        "response.code_interpreter_call_code.", "response.mcp_call_arguments.",
        "response.mcp_call.", "response.mcp_list_tools.",
        "response.shell_call_command.", "response.shell_call_output_content."
    ]

    init(provider: GenerationProvider) { self.provider = provider }

    mutating func consume(_ event: ServerSentEvent, status: Int? = nil, requestID: String? = nil, redacting credential: ConnectionSecret? = nil) throws -> String? {
        if event.data == "[DONE]" {
            guard provider == .openRouter, stopped else { throw GenerationError.interrupted }
            return try completedText()
        }
        guard let data = event.data.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw GenerationError.invalidResponse }
        if payload["error"] != nil || payload["type"] as? String == "error" || event.name == "error" {
            throw GenerationError.providerFailure(GenerationFailure(provider: provider, status: status, payload: payload, requestID: requestID, redacting: credential))
        }
        switch provider {
        case .chatGPT: return try consumeResponses(payload, event: event, status: status, requestID: requestID, redacting: credential)
        case .openRouter: return try consumeOpenRouter(payload)
        case .legacyCLI: throw GenerationError.invalidResponse
        }
    }

    private mutating func consumeResponses(_ payload: [String: Any], event: ServerSentEvent, status: Int?, requestID: String?, redacting credential: ConnectionSecret?) throws -> String? {
        guard let type = payload["type"] as? String,
              event.name == nil || event.name == type else { throw GenerationError.invalidResponse }
        if Self.responseToolEventPrefixes.contains(where: type.hasPrefix) { throw GenerationError.incomplete }
        try responseItems.record(payload)
        switch type {
        case "response.output_text.delta":
            guard let delta = payload["delta"] as? String else { throw GenerationError.invalidResponse }
            text += delta
        case "response.refusal.delta", "response.refusal.done": throw GenerationError.refused
        case "response.failed":
            let response = payload["response"] as? [String: Any] ?? [:]
            throw GenerationError.providerFailure(GenerationFailure(provider: provider, status: status, payload: response, requestID: requestID, redacting: credential))
        case "response.incomplete": throw GenerationError.incomplete
        case "response.completed":
            guard let response = payload["response"] as? [String: Any], response["status"] as? String == "completed"
            else { throw GenerationError.invalidResponse }
            if response["error"] is [String: Any] {
                throw GenerationError.providerFailure(GenerationFailure(provider: provider, status: status, payload: response, requestID: requestID, redacting: credential))
            }
            guard response["error"] == nil || response["error"] is NSNull else { throw GenerationError.invalidResponse }
            if response["incomplete_details"] is [String: Any] { throw GenerationError.incomplete }
            guard response["incomplete_details"] == nil || response["incomplete_details"] is NSNull
            else { throw GenerationError.invalidResponse }
            guard let output = response["output"] as? [[String: Any]] else { throw GenerationError.invalidResponse }
            var terminalText = ""
            for item in output {
                if let status = item["status"] as? String, status != "completed" { throw GenerationError.incomplete }
                for content in item["content"] as? [[String: Any]] ?? [] {
                    if content["type"] as? String == "refusal" { throw GenerationError.refused }
                    if content["type"] as? String == "output_text", let value = content["text"] as? String { terminalText += value }
                }
            }
            let completedItemText = try responseItems.text(at: response)
            // Live ChatGPT plan streams can send output=[] after independently
            // completed message/content items. Keep response.completed as the
            // delivery fence and recover only the fully correlated done chain;
            // a nonempty terminal array is authoritative, including empty text.
            if output.isEmpty, let completedItemText { terminalText = completedItemText }
            guard !terminalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GenerationError.emptyOutput }
            if !text.isEmpty, text != terminalText { throw GenerationError.invalidResponse }
            text = terminalText
            return try completedText()
        default: break // Lifecycle, reasoning and accounting events carry no output.
        }
        return nil
    }

    private mutating func consumeOpenRouter(_ payload: [String: Any]) throws -> String? {
        guard let choices = payload["choices"] as? [[String: Any]] else { throw GenerationError.invalidResponse }
        for choice in choices {
            guard choice["index"] as? Int == 0 else { throw GenerationError.invalidResponse }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let refusal = delta["refusal"] as? String, !refusal.isEmpty { throw GenerationError.refused }
            if delta["tool_calls"] != nil || delta["function_call"] != nil { throw GenerationError.incomplete }
            if let content = delta["content"] as? String, !content.isEmpty {
                guard !stopped else { throw GenerationError.invalidResponse }
                text += content
            }
            if let reason = choice["finish_reason"] as? String {
                guard reason == "stop" else {
                    if reason == "content_filter" { throw GenerationError.refused }
                    throw GenerationError.incomplete
                }
                stopped = true // The accounting chunk may repeat "stop".
            }
        }
        return nil
    }

    private func completedText() throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GenerationError.emptyOutput }
        return text
    }
}
