import Foundation
import Yams

public final class ConfigStore {
    private let configURL: URL

    public init(configURL: URL = ConfigStore.defaultConfigURL()) {
        self.configURL = configURL
    }

    public var runtimeSettingsURL: URL {
        configURL
            .deletingLastPathComponent()
            .appendingPathComponent("runtime.json", isDirectory: false)
    }

    public static func defaultConfigURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("sable", isDirectory: true)
            .appendingPathComponent("config.yaml", isDirectory: false)
    }

    /// Loads and validates Sable's YAML config before app services consume it.
    public func load() throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw SableError.configNotFound(configURL)
        }

        let data = try Data(contentsOf: configURL)
        let config = try YAMLDecoder().decode(AppConfig.self, from: data)
        try validate(config)
        return config
    }

    public func readRuntimeSettings() throws -> RuntimeSettings {
        guard FileManager.default.fileExists(atPath: runtimeSettingsURL.path) else {
            return RuntimeSettings()
        }
        let data = try Data(contentsOf: runtimeSettingsURL)
        return try JSONDecoder().decode(RuntimeSettings.self, from: data)
    }

    /// Persists user-selected CLI executable paths separately from the YAML hotkey config.
    public func writeRuntimeSettings(_ settings: RuntimeSettings) throws {
        try FileManager.default.createDirectory(
            at: runtimeSettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: runtimeSettingsURL, options: .atomic)
    }

    private func validate(_ config: AppConfig) throws {
        guard !config.runtime.cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SableError.invalidConfig("runtime.cwd must not be empty")
        }
        guard config.runtime.timeoutSeconds > 0 else {
            throw SableError.invalidConfig("runtime.timeout_seconds must be greater than 0")
        }
        _ = try HotkeyParser.parse(config.hotkeys.quickFix)
        _ = try HotkeyParser.parse(config.hotkeys.ask)
    }
}
