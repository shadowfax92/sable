import XCTest
@testable import SableCore

final class ConfigStoreTests: XCTestCase {
    func testLoadsRuntimeConfigFromYAML() throws {
        let configURL = try writeConfig("""
        hotkeys:
          quick_fix: "ctrl+option+cmd+k"
          ask: "ctrl+option+cmd+j"
        capture:
          selected_text_fallback: "copy"
          screenshot:
            enabled: true
            target: "frontmost_window"
            fallback: "screen"
            format: "png"
        runtime:
          id: codex
          cwd: "~"
          timeout_seconds: 60
        prompts:
          quick_fix: "Fix grammar. Return only the corrected text."
        """)

        let config = try ConfigStore(configURL: configURL).load()

        XCTAssertEqual(config.hotkeys.quickFix, "ctrl+option+cmd+k")
        XCTAssertEqual(config.hotkeys.ask, "ctrl+option+cmd+j")
        XCTAssertEqual(config.runtime.id, .codex)
        XCTAssertEqual(config.runtime.cwd, "~")
        XCTAssertEqual(config.runtime.timeoutSeconds, 60)
        XCTAssertEqual(config.prompts.quickFix, "Fix grammar. Return only the corrected text.")
    }

    func testLoadsLegacyClaudeConfigAsClaudeRuntime() throws {
        let configURL = try writeConfig("""
        hotkeys:
          quick_fix: "ctrl+option+cmd+k"
          ask: "ctrl+option+cmd+j"
        capture:
          selected_text_fallback: "copy"
          screenshot:
            enabled: true
            target: "frontmost_window"
            fallback: "screen"
            format: "png"
        claude:
          command: "claude"
          args: ["--print", "-"]
          cwd: "~"
          timeout_seconds: 60
        prompts:
          quick_fix: "Fix grammar."
        """)

        let config = try ConfigStore(configURL: configURL).load()

        XCTAssertEqual(config.runtime.id, .claude)
        XCTAssertEqual(config.runtime.cwd, "~")
        XCTAssertEqual(config.runtime.timeoutSeconds, 60)
    }

    func testDefaultConfigPathUsesHomeConfigDirectory() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(
            ConfigStore.defaultConfigURL(homeDirectory: home).path,
            "/Users/example/.config/sable/config.yaml"
        )
    }

    func testRejectsEmptyRuntimeCWD() throws {
        let configURL = try writeConfig("""
        hotkeys:
          quick_fix: "ctrl+option+cmd+k"
          ask: "ctrl+option+cmd+j"
        capture:
          selected_text_fallback: "copy"
          screenshot:
            enabled: true
            target: "frontmost_window"
            fallback: "screen"
            format: "png"
        runtime:
          id: claude
          cwd: ""
          timeout_seconds: 60
        prompts:
          quick_fix: "Fix grammar."
        """)

        XCTAssertThrowsError(try ConfigStore(configURL: configURL).load()) { error in
            XCTAssertEqual(error as? SableError, .invalidConfig("runtime.cwd must not be empty"))
        }
    }

    func testReadsAndWritesRuntimeSettings() throws {
        let temp = try temporaryDirectory()
        let store = ConfigStore(configURL: temp.appendingPathComponent("config.yaml"))
        let settings = RuntimeSettings(
            claudePath: "/Users/me/.local/bin/claude",
            codexPath: "/Users/me/.local/bin/codex"
        )

        try store.writeRuntimeSettings(settings)

        XCTAssertEqual(try store.readRuntimeSettings(), settings)
        XCTAssertEqual(store.runtimeSettingsURL.path, temp.appendingPathComponent("runtime.json").path)
    }

    func testMissingRuntimeSettingsReturnsDefaults() throws {
        let temp = try temporaryDirectory()
        let store = ConfigStore(configURL: temp.appendingPathComponent("config.yaml"))

        XCTAssertEqual(try store.readRuntimeSettings(), RuntimeSettings())
    }

    private func writeConfig(_ contents: String) throws -> URL {
        let temp = try temporaryDirectory()
        let configURL = temp.appendingPathComponent("config.yaml")
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    private func temporaryDirectory() throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }
}
