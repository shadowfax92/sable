import Foundation
import Yams

public final class ConfigStore {
    private let configURL: URL

    public init(configURL: URL = ConfigStore.defaultConfigURL()) {
        self.configURL = configURL
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

    private func validate(_ config: AppConfig) throws {
        guard !config.claude.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SableError.invalidConfig("claude.command must not be empty")
        }
        guard config.claude.args.contains("-") else {
            throw SableError.invalidConfig("claude.args must include '-' so Sable can pass the prompt on stdin")
        }
        guard config.claude.timeoutSeconds > 0 else {
            throw SableError.invalidConfig("claude.timeout_seconds must be greater than 0")
        }
        _ = try HotkeyParser.parse(config.hotkeys.quickFix)
        _ = try HotkeyParser.parse(config.hotkeys.ask)
    }
}
