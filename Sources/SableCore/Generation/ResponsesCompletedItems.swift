import Foundation

/// Correlates the Responses message lifecycle without publishing intermediate
/// text. ChatGPT plan streams can omit duplicated items from response.completed;
/// only a fully matched item/content completion chain can supply that body.
struct ResponsesCompletedItems {
    private struct PartID: Hashable {
        let output: Int
        let item: String
        let content: Int
    }

    private struct Content: Equatable {
        let type: String
        let text: String?

        init(_ object: [String: Any]) throws {
            guard let type = object["type"] as? String else { throw GenerationError.invalidResponse }
            if type == "refusal" { throw GenerationError.refused }
            self.type = type
            // Reasoning and tool content never enter the replacement-text buffer.
            text = type == "output_text" ? object["text"] as? String : nil
            if type == "output_text", text == nil { throw GenerationError.invalidResponse }
        }
    }

    private struct Item: Equatable {
        let id: String
        let type: String
        let role: String?
        let phase: String?
        let channel: String?
        let status: String?
        let content: [Content]

        init(_ object: [String: Any]) throws {
            guard let id = object["id"] as? String, !id.isEmpty,
                  let type = object["type"] as? String else { throw GenerationError.invalidResponse }
            self.id = id; self.type = type
            role = object["role"] as? String
            phase = object["phase"] as? String
            channel = object["channel"] as? String
            status = object["status"] as? String
            if type == "message" {
                guard let parts = object["content"] as? [[String: Any]],
                      object["phase"] == nil || object["phase"] is NSNull || phase != nil,
                      object["channel"] == nil || object["channel"] is NSNull || channel != nil
                else { throw GenerationError.invalidResponse }
                content = try parts.map(Content.init)
            } else { content = [] }
        }
    }

    private var responseID: String?
    private var added: [Int: Item] = [:]
    private var done: [Int: Item] = [:]
    private var startedParts: Set<PartID> = []
    private var deltas: [PartID: String] = [:]
    private var textDone: [PartID: String] = [:]
    private var contentDone: [PartID: Content] = [:]
    private var sawItems = false
    private var failure: GenerationError?

    /// Retain correlation failures until the response fence. Older terminal-body
    /// streams need not include item events, but cannot use this recovery path.
    mutating func record(_ payload: [String: Any]) throws {
        do { try recordEvent(payload) }
        catch let error as GenerationError {
            if error == .refused { throw error }
            if failure == nil { failure = error }
        }
    }

    private mutating func recordEvent(_ payload: [String: Any]) throws {
        switch payload["type"] as? String {
        case "response.created", "response.in_progress":
            guard let response = payload["response"] as? [String: Any],
                  let id = response["id"] as? String, !id.isEmpty,
                  responseID == nil || responseID == id else { throw GenerationError.invalidResponse }
            responseID = id
        case "response.output_item.added", "response.output_item.done":
            sawItems = true
            guard let index = payload["output_index"] as? Int, index >= 0,
                  let object = payload["item"] as? [String: Any] else { throw GenerationError.invalidResponse }
            let item = try Item(object)
            if payload["type"] as? String == "response.output_item.added" {
                guard added[index] == nil, !added.values.contains(where: { $0.id == item.id })
                else { throw GenerationError.invalidResponse }
                added[index] = item
            } else {
                guard let start = added[index], done[index] == nil,
                      start.id == item.id, start.type == item.type, start.role == item.role,
                      start.phase == nil || start.phase == item.phase,
                      start.channel == item.channel else { throw GenerationError.invalidResponse }
                if let status = item.status, status != "completed" { throw GenerationError.incomplete }
                if item.type == "message" {
                    guard item.status == "completed", item.role == "assistant", item.channel == nil,
                          item.phase == nil || item.phase == "final_answer" else { throw GenerationError.invalidResponse }
                    for (contentIndex, content) in item.content.enumerated() {
                        let key = PartID(output: index, item: item.id, content: contentIndex)
                        guard content.type == "output_text", startedParts.contains(key),
                              let delta = deltas[key], delta == content.text,
                              textDone[key] == content.text, contentDone[key] == content
                        else { throw GenerationError.invalidResponse }
                    }
                } else if item.type != "reasoning" {
                    // No tools are requested by direct rewrites. A tool result
                    // cannot stand in for a completed assistant replacement.
                    throw GenerationError.incomplete
                }
                done[index] = item
            }
        case "response.output_text.delta", "response.output_text.done", "response.content_part.added", "response.content_part.done":
            guard let output = payload["output_index"] as? Int, output >= 0,
                  let item = payload["item_id"] as? String,
                  let content = payload["content_index"] as? Int, content >= 0,
                  added[output]?.id == item, done[output] == nil else { throw GenerationError.invalidResponse }
            let key = PartID(output: output, item: item, content: content)
            if added[output]?.type == "reasoning" {
                // Reasoning content has its own lifecycle but is never pasteable
                // text. Correlate its owner, without retaining its private text.
                guard let object = payload["part"] as? [String: Any],
                      try Content(object).type == "reasoning_text"
                else { throw GenerationError.invalidResponse }
                return
            }
            switch payload["type"] as? String {
            case "response.content_part.added":
                guard let object = payload["part"] as? [String: Any] else { throw GenerationError.invalidResponse }
                let part = try Content(object)
                guard part.type == "output_text", part.text == "", startedParts.insert(key).inserted
                else { throw GenerationError.invalidResponse }
            case "response.output_text.delta":
                guard startedParts.contains(key), textDone[key] == nil, contentDone[key] == nil,
                      let delta = payload["delta"] as? String else { throw GenerationError.invalidResponse }
                deltas[key, default: ""] += delta
            case "response.output_text.done":
                guard let text = payload["text"] as? String, textDone[key] == nil,
                      let delta = deltas[key], delta == text else { throw GenerationError.invalidResponse }
                textDone[key] = text
            default:
                guard let object = payload["part"] as? [String: Any], contentDone[key] == nil
                else { throw GenerationError.invalidResponse }
                let part = try Content(object)
                guard part.type == "output_text", let text = textDone[key], text == part.text
                else { throw GenerationError.invalidResponse }
                contentDone[key] = part
            }
        default: break
        }
    }

    /// Called only after response.completed has passed status/error/schema checks.
    /// The terminal body stays authoritative when present; an empty array may use
    /// completed items only when no item, part or response identity is unresolved.
    func text(at response: [String: Any]) throws -> String? {
        guard sawItems else { return nil }
        if let failure { throw failure }
        guard let responseID, response["id"] as? String == responseID,
              !added.isEmpty, added.count == done.count,
              added.keys.sorted() == Array(0..<added.count) else { throw GenerationError.invalidResponse }
        let ordered = done.keys.sorted().compactMap { done[$0] }
        var expectedParts: Set<PartID> = []
        var result = ""
        for (index, item) in ordered.enumerated() where item.type == "message" {
            for (contentIndex, part) in item.content.enumerated() {
                expectedParts.insert(PartID(output: index, item: item.id, content: contentIndex))
                result += part.text ?? ""
            }
        }
        guard expectedParts == startedParts, expectedParts == Set(deltas.keys),
              expectedParts == Set(textDone.keys), expectedParts == Set(contentDone.keys)
        else { throw GenerationError.invalidResponse }
        if let output = response["output"] as? [[String: Any]], !output.isEmpty {
            guard try output.map(Item.init) == ordered else { throw GenerationError.invalidResponse }
        }
        return result
    }
}
