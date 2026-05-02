import XCTest
@testable import SableCore

final class RunHistoryStoreTests: XCTestCase {
    func testUpsertInsertsNewestRecordFirst() {
        let older = RunRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 10),
            completedAt: nil,
            status: .copied,
            instruction: "Fix",
            selectedText: "old",
            screenshotPath: nil,
            outputText: "Old",
            errorMessage: nil
        )
        let newer = RunRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 20),
            completedAt: nil,
            status: .running,
            instruction: "Rewrite",
            selectedText: "new",
            screenshotPath: nil,
            outputText: nil,
            errorMessage: nil
        )

        let records = RunHistoryStore.upserting(newer, into: [older], maxRecords: 50)

        XCTAssertEqual(records.map(\.id), [newer.id, older.id])
    }

    func testUpsertReplacesExistingRecord() {
        let id = UUID()
        let original = RunRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: 10),
            completedAt: nil,
            status: .running,
            instruction: "Fix",
            selectedText: "bad",
            screenshotPath: nil,
            outputText: nil,
            errorMessage: nil
        )
        let updated = RunRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 12),
            status: .copied,
            instruction: "Fix",
            selectedText: "bad",
            screenshotPath: "/tmp/screenshot.png",
            outputText: "Good",
            errorMessage: nil
        )

        let records = RunHistoryStore.upserting(updated, into: [original], maxRecords: 50)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].status, .copied)
        XCTAssertEqual(records[0].outputText, "Good")
    }

    func testUpsertTrimsToMaxRecords() {
        let records = (0..<4).map { index in
            RunRecord(
                id: UUID(),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                completedAt: nil,
                status: .copied,
                instruction: "\(index)",
                selectedText: "",
                screenshotPath: nil,
                outputText: nil,
                errorMessage: nil
            )
        }
        let newest = RunRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 10),
            completedAt: nil,
            status: .running,
            instruction: "new",
            selectedText: "",
            screenshotPath: nil,
            outputText: nil,
            errorMessage: nil
        )

        let trimmed = RunHistoryStore.upserting(newest, into: records, maxRecords: 3)

        XCTAssertEqual(trimmed.count, 3)
        XCTAssertEqual(trimmed.first?.id, newest.id)
    }

    func testSaveLoadAndClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        let store = RunHistoryStore(historyURL: url, maxRecords: 50)
        let record = RunRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11),
            status: .failed,
            instruction: "Fix",
            selectedText: "input",
            screenshotPath: "/tmp/screenshot.png",
            outputText: nil,
            errorMessage: "No selected text"
        )

        try store.save([record])
        XCTAssertEqual(try store.load(), [record])

        try store.clear()
        XCTAssertEqual(try store.load(), [])
    }
}
