import Foundation

public final class RunHistoryStore {
    private let historyURL: URL
    private let maxRecords: Int

    public init(
        historyURL: URL = RunHistoryStore.defaultHistoryURL(),
        maxRecords: Int = 50
    ) {
        self.historyURL = historyURL
        self.maxRecords = maxRecords
    }

    public static func defaultHistoryURL(
        applicationSupportDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Sable", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    public static func upserting(
        _ record: RunRecord,
        into records: [RunRecord],
        maxRecords: Int
    ) -> [RunRecord] {
        let withoutExisting = records.filter { $0.id != record.id }
        let sorted = ([record] + withoutExisting)
            .sorted { lhs, rhs in lhs.createdAt > rhs.createdAt }
        return Array(sorted.prefix(maxRecords))
    }

    /// Loads persisted run history, returning an empty list when no history exists yet.
    public func load() throws -> [RunRecord] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            return []
        }

        let data = try Data(contentsOf: historyURL)
        return try JSONDecoder.sable.decode([RunRecord].self, from: data)
    }

    public func save(_ records: [RunRecord]) throws {
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let trimmed = Array(records.prefix(maxRecords))
        let data = try JSONEncoder.sable.encode(trimmed)
        try data.write(to: historyURL, options: [.atomic])
    }

    public func upsert(_ record: RunRecord) throws -> [RunRecord] {
        let updated = Self.upserting(record, into: try load(), maxRecords: maxRecords)
        try save(updated)
        return updated
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: historyURL.path) {
            try FileManager.default.removeItem(at: historyURL)
        }
    }
}

private extension JSONEncoder {
    static var sable: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var sable: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
