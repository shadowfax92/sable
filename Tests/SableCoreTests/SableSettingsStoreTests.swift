import XCTest
@testable import SableCore

final class SableSettingsStoreTests: XCTestCase {
    func testLoadSeedsStandardSettingsAndPersists() throws {
        let url = try temporaryFile()
        let store = SableSettingsStore(url: url)

        let loaded = try store.load()

        XCTAssertEqual(loaded.modes.count, SableSettings.defaultModes.count)
        XCTAssertNotNil(loaded.defaultMode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "seed should be written so mode ids stay stable")
    }

    func testSeededModeIDsStayStableAcrossLoads() throws {
        let url = try temporaryFile()
        let store = SableSettingsStore(url: url)

        let first = try store.load()
        let second = try store.load()

        XCTAssertEqual(first.modes.map(\.id), second.modes.map(\.id))
    }

    func testRoundTripsCustomSettings() throws {
        let url = try temporaryFile()
        let store = SableSettingsStore(url: url)
        let mode = SableMode(
            name: "Translate",
            symbol: "globe",
            instruction: "Translate to French.",
            runtimeID: .codex,
            model: "gpt-5.5",
            requiresInput: true
        )
        let settings = SableSettings(
            modes: [mode],
            runtimePaths: RuntimeSettings(claudePath: "/bin/claude", codexPath: "/bin/codex"),
            cwd: "~/work",
            timeoutSeconds: 90,
            defaultModeID: mode.id
        )

        try store.save(settings)

        XCTAssertEqual(try store.load(), settings)
    }

    func testDefaultModeFallsBackToFirstWhenIDMissing() {
        let settings = SableSettings(modes: SableSettings.defaultModes, defaultModeID: UUID())
        XCTAssertEqual(settings.defaultMode, settings.modes.first)
    }

    private func temporaryFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }
}
