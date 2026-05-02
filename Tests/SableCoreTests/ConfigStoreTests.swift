import XCTest
@testable import SableCore

final class ConfigStoreTests: XCTestCase {
    func testLoadsConfigFromYAML() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let configURL = temp.appendingPathComponent("config.yaml")
        try """
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
          args: ["--print", "-", "--output-format", "stream-json"]
          cwd: "~"
          timeout_seconds: 60
        prompts:
          quick_fix: "Fix grammar. Return only the corrected text."
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let config = try ConfigStore(configURL: configURL).load()

        XCTAssertEqual(config.hotkeys.quickFix, "ctrl+option+cmd+k")
        XCTAssertEqual(config.hotkeys.ask, "ctrl+option+cmd+j")
        XCTAssertEqual(config.claude.command, "claude")
        XCTAssertEqual(config.claude.args, ["--print", "-", "--output-format", "stream-json"])
        XCTAssertEqual(config.claude.timeoutSeconds, 60)
        XCTAssertEqual(config.prompts.quickFix, "Fix grammar. Return only the corrected text.")
    }

    func testDefaultConfigPathUsesHomeConfigDirectory() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(
            ConfigStore.defaultConfigURL(homeDirectory: home).path,
            "/Users/example/.config/sable/config.yaml"
        )
    }

    func testRejectsEmptyClaudeCommand() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let configURL = temp.appendingPathComponent("config.yaml")
        try """
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
          command: ""
          args: ["--print", "-"]
          cwd: "~"
          timeout_seconds: 60
        prompts:
          quick_fix: "Fix grammar."
        """.write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ConfigStore(configURL: configURL).load()) { error in
            XCTAssertEqual(error as? SableError, .invalidConfig("claude.command must not be empty"))
        }
    }
}
