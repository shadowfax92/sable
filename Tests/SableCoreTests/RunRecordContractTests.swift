import XCTest
@testable import SableCore

/// Legacy JSON is a literal pre-metadata history entry. These checks exercise
/// the persisted contract and store identity without touching the owner's history.
final class RunRecordContractTests: XCTestCase {
    private let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let legacyJSON = """
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "createdAt": "2026-10-28T12:00:00Z",
      "completedAt": "2026-10-28T12:00:01Z",
      "status": "copied",
      "instruction": "Fix grammar",
      "selectedText": "before",
      "outputText": "after"
    }
    """

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func testLegacyJSONDecodesEveryExistingStatusWithoutMetadata() throws {
        let statuses: [RunStatus] = [.capturing, .running, .copied, .failed, .cancelled]
        for status in statuses {
            let json = legacyJSON.replacingOccurrences(of: "\"copied\"", with: "\"\(status.rawValue)\"")
            let record = try decoder().decode(RunRecord.self, from: Data(json.utf8))
            XCTAssertEqual(record.id, legacyID)
            XCTAssertEqual(record.status, status)
            XCTAssertEqual(record.instruction, "Fix grammar")
            XCTAssertEqual(record.selectedText, "before")
            XCTAssertEqual(record.outputText, "after")
            XCTAssertNotNil(record.createdAt)
            XCTAssertNotNil(record.completedAt)
            XCTAssertNil(record.modeName)
            XCTAssertNil(record.provider)
            XCTAssertNil(record.model)
        }
    }

    func testExistingInitializerKeepsNilMetadataDefaults() throws {
        let record = RunRecord(
            id: legacyID, createdAt: Date(timeIntervalSince1970: 10), completedAt: nil,
            status: .running, instruction: "Fix", selectedText: "input",
            screenshotPath: nil, outputText: nil, errorMessage: nil
        )
        XCTAssertNil(record.modeName)
        XCTAssertNil(record.provider)
        XCTAssertNil(record.model)
        XCTAssertEqual(try decoder().decode(RunRecord.self, from: encoder().encode(record)), record)
    }

    func testNewStatusesAndProviderMetadataRoundTrip() throws {
        let statuses: [(RunStatus, String)] = [(.review, "Review"), (.pasted, "Pasted"), (.discarded, "Discarded")]
        let providers: [GenerationProvider] = [.legacyCLI, .chatGPT, .openRouter]
        for (status, displayName) in statuses {
            for provider in providers {
                let record = RunRecord(
                    id: legacyID, createdAt: Date(timeIntervalSince1970: 10),
                    completedAt: status == .review ? nil : Date(timeIntervalSince1970: 12),
                    status: status, instruction: "Fix", selectedText: "e\u{301} before",
                    screenshotPath: nil, outputText: "edited 👩🏽‍💻", errorMessage: nil,
                    modeName: "My custom mode", provider: provider, model: "account-model"
                )
                let data = try encoder().encode(record)
                let restored = try decoder().decode(RunRecord.self, from: data)
                XCTAssertEqual(restored, record)
                XCTAssertEqual(restored.id, legacyID)
                XCTAssertEqual(restored.status.displayName, displayName)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(json["status"] as? String, status.rawValue)
                XCTAssertEqual(json["provider"] as? String, provider.rawValue)
                XCTAssertEqual(json["modeName"] as? String, "My custom mode")
                XCTAssertEqual(json["model"] as? String, "account-model")
            }
        }
    }

    func testHistoryPreservesLegacyRecordsAndStableIDsDuringNewOutcomes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sable-history-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        try Data("[\(legacyJSON)]".utf8).write(to: url)
        let store = RunHistoryStore(historyURL: url)
        let original = try XCTUnwrap(store.load().first)
        XCTAssertEqual(original.id, legacyID)

        let newerID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let newer = RunRecord(
            id: newerID, createdAt: original.createdAt.addingTimeInterval(10),
            completedAt: original.createdAt.addingTimeInterval(12), status: .discarded,
            instruction: "Rewrite", selectedText: "new input", screenshotPath: nil,
            outputText: "discarded edits are retained", errorMessage: nil,
            modeName: "Custom", provider: .chatGPT, model: "catalog-model"
        )
        _ = try store.upsert(newer)
        XCTAssertEqual(try store.load(), [newer, original])

        var reviewed = original
        reviewed.status = .review
        reviewed.completedAt = nil
        reviewed.outputText = "working review text"
        reviewed.modeName = "My old mode"
        reviewed.provider = .legacyCLI
        reviewed.model = "legacy-alias"
        _ = try store.upsert(reviewed)
        var pasted = reviewed
        pasted.status = .pasted
        pasted.completedAt = original.createdAt.addingTimeInterval(15)
        pasted.outputText = "final edited text"
        _ = try store.upsert(pasted)

        let reloaded = try RunHistoryStore(historyURL: url).load()
        XCTAssertEqual(reloaded, [newer, pasted])
        XCTAssertEqual(Set(reloaded.map(\.id)), [newerID, legacyID])
        XCTAssertEqual(reloaded.count, 2, "Outcome updates replace the same run rather than create new IDs")
    }
}
