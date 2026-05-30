import Foundation

/// Reads and writes the app-owned settings JSON. Unlike the old read-only YAML
/// config, this is the source of truth the in-app UI edits. First launch seeds
/// and persists `SableSettings.standard` so mode ids (and therefore their
/// hotkeys) stay stable from the very first run.
public final class SableSettingsStore {
    private let url: URL

    public init(url: URL = SableSettingsStore.defaultURL()) {
        self.url = url
    }

    public var settingsURL: URL { url }

    public static func defaultURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("sable", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    public func load() throws -> SableSettings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let seed = SableSettings.standard
            try? save(seed)
            return seed
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SableSettings.self, from: data)
    }

    public func save(_ settings: SableSettings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: .atomic)
    }
}
